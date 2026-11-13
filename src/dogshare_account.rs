use base::message_proto::{login_request, LoginRequest};
use hbb_common::{anyhow::anyhow, bail, config::Config, rendezvous_proto::ConnType, tokio, ResultType};
use serde_json::{json, Value};
use std::{
    ffi::CString,
    future::Future,
    os::raw::c_char,
    pin::Pin,
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

pub const API_SERVER: &str = if crate::dogshare_role::is_split() {
    "https://phenoseed.com/dogshare-paired-account"
} else {
    "https://phenoseed.com/dogshare-account"
};
pub const RECHECK_INTERVAL: Duration = Duration::from_secs(30);
const HTTP_TIMEOUT: Duration = Duration::from_secs(8);
const FIRST_FRAME_TIMEOUT: Duration = Duration::from_secs(60);
const ACTIVATION_RETRY_DELAY: Duration = Duration::from_millis(400);
const OVERLAY_LEASE: Duration = Duration::from_secs(75);
const RESPONSE_LIMIT: usize = 32 * 1024;
const SIGN_IN_REQUIRED: &str = "Sign in to your DogShare account first.";

#[derive(Default)]
struct Lease {
    generation: u64,
    deadline: Option<Instant>,
    expires_at: u64,
    user: Option<Value>,
    error: String,
}

lazy_static::lazy_static! {
    static ref LEASE: Mutex<Lease> = Mutex::new(Lease::default());
}

struct Authorization {
    expires_at: u64,
    user: Value,
}

fn unix_now() -> ResultType<u64> {
    Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs())
}

fn identity() -> ResultType<(String, String)> {
    let id = Config::get_id();
    validate_device_id(&id)?;
    Ok((id, crate::ui_interface::get_uuid()))
}

fn access_token() -> ResultType<String> {
    crate::dogshare_role::require_user_session()?;
    let token = crate::dogshare_credentials::read_access_token();
    if token.is_empty() {
        bail!(SIGN_IN_REQUIRED);
    }
    Ok(token)
}

fn validate_device_id(id: &str) -> ResultType<()> {
    if id.is_empty() || id.len() > 256 || id.trim() != id || id.contains('@') {
        bail!("A registered DogShare device ID is required.");
    }
    if hbb_common::is_ip_str(id) || hbb_common::is_domain_port_str(id) {
        bail!("Direct IP connections are unavailable: use the registered DogShare device ID.");
    }
    Ok(())
}

pub fn connection_type(kind: ConnType) -> &'static str {
    match kind {
        ConnType::FILE_TRANSFER => "file_transfer",
        ConnType::VIEW_CAMERA => "view_camera",
        ConnType::PORT_FORWARD | ConnType::RDP => "port_forward",
        ConnType::TERMINAL => "terminal",
        ConnType::DEFAULT_CONN => "remote",
        _ => "unsupported",
    }
}

fn login_type(login: &LoginRequest) -> &'static str {
    match login.union.as_ref() {
        Some(login_request::Union::FileTransfer(_)) => "file_transfer",
        Some(login_request::Union::ViewCamera(_)) => "view_camera",
        Some(login_request::Union::PortForward(_)) => "port_forward",
        Some(login_request::Union::Terminal(_)) => "terminal",
        Some(_) => "unsupported",
        None => "remote",
    }
}

fn request_body() -> ResultType<Value> {
    let (id, uuid) = identity()?;
    Ok(json!({"id": id, "uuid": uuid}))
}

fn parse_response(status: u16, bytes: &[u8]) -> ResultType<Value> {
    if status != 200 {
        if status == 401 {
            bail!("DogShare account session is invalid or expired. Sign in again.");
        }
        if status == 403 && bytes.len() <= RESPONSE_LIMIT {
            if let Ok(error) = serde_json::from_slice::<Value>(bytes) {
                match error["code"].as_str() {
                    Some("pair_expired") => bail!("This DogShare account pair has expired. Contact the administrator."),
                    Some("pair_activation_unsupported") => bail!("Update DogShare A to use this time-limited account pair."),
                    Some("pair_activation_timeout") => bail!("DogShare pair activation timed out. Connect again."),
                    _ => {}
                }
            }
        }
        bail!(
            "DogShare account authorization was rejected (HTTP {}).",
            status
        );
    }
    if bytes.len() > RESPONSE_LIMIT {
        bail!("Invalid DogShare account response.");
    }
    let value: Value = serde_json::from_slice(bytes)?;
    if !value.is_object() || value.get("error").is_some() {
        bail!("Invalid DogShare account response.");
    }
    Ok(value)
}

async fn post_response(path: &str, token: &str, body: &Value) -> ResultType<(u16, Vec<u8>)> {
    let client = reqwest::Client::builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(HTTP_TIMEOUT)
        .build()?;
    let mut response = client
        .post(format!("{API_SERVER}/api/dogshare/{path}"))
        .bearer_auth(token)
        .json(body)
        .send()
        .await?;
    let status = response.status().as_u16();
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        if bytes.len().saturating_add(chunk.len()) > RESPONSE_LIMIT {
            bail!("Invalid DogShare account response.");
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok((status, bytes))
}

async fn post(path: &str, token: &str, body: Value) -> ResultType<Value> {
    let (status, bytes) = post_response(path, token, &body).await?;
    parse_response(status, &bytes)
}

fn parse_authorization(value: Value, action: &str, now: u64) -> ResultType<Authorization> {
    let expires_at = value["expires_at"].as_u64().unwrap_or(0);
    let user = &value["user"];
    crate::dogshare_role::require_account_role(user["role"].as_str())?;
    if expires_at <= now
        || value["permissions"][action].as_bool() != Some(true)
        || user["status"].as_i64() != Some(1)
        || user["name"].as_str().map_or(true, str::is_empty)
    {
        bail!("DogShare account permission is unavailable or expired.");
    }
    Ok(Authorization {
        expires_at,
        user: user.clone(),
    })
}

async fn authorize_remote(token: &str) -> ResultType<()> {
    let mut body = request_body()?;
    body["action"] = json!("remote");
    parse_authorization(post("authorize", token, body).await?, "remote", unix_now()?)?;
    Ok(())
}

// The bearer and identity belong to the same login attempt as the ticket.
// Reading current credentials later could report against a different sign-in.
pub(crate) struct PairActivationProof {
    token: String,
    body: Value,
}

#[derive(Clone)]
pub(crate) struct FirstDecodedFrame(Arc<Mutex<Option<tokio::sync::oneshot::Sender<()>>>>);

impl FirstDecodedFrame {
    pub(crate) fn signal(self) {
        if let Some(sender) = self.0.lock().unwrap().take() {
            // No receiver means this connection has already ended.
            let _ = sender.send(());
        }
    }
}

type ActivationFuture = Pin<Box<dyn Future<Output = ResultType<()>> + Send>>;

pub(crate) struct PairActivation {
    pub(crate) first_frame: FirstDecodedFrame,
    // Remote's other async methods also borrow it immutably across awaits.
    finish: Mutex<ActivationFuture>,
}

impl PairActivation {
    pub(crate) fn new(proof: PairActivationProof) -> Self {
        let (sender, receiver) = tokio::sync::oneshot::channel();
        let deadline = tokio::time::Instant::now() + FIRST_FRAME_TIMEOUT;
        Self {
            first_frame: FirstDecodedFrame(Arc::new(Mutex::new(Some(sender)))),
            finish: Mutex::new(Box::pin(async move {
                if !matches!(tokio::time::timeout_at(deadline, receiver).await, Ok(Ok(()))) {
                    bail!("DogShare pair activation timed out waiting for the remote screen. Connect again.");
                }
                proof.activate().await
            })),
        }
    }

    // This future stays owned by the current connection; a reconnect drops it.
    // Poll it in select! without awaiting HTTP on the peer or decoder path.
    pub(crate) async fn wait(activation: &mut Option<Self>) -> ResultType<()> {
        match activation {
            // Exclusive access means no lock is taken or held across await.
            Some(activation) => activation.finish.get_mut().unwrap().as_mut().await,
            None => std::future::pending().await,
        }
    }
}

fn parse_activation_response(value: Value) -> ResultType<()> {
    if value["activated"].as_bool() != Some(true) || value["expires_at"].as_u64().unwrap_or(0) == 0 {
        bail!("Invalid DogShare pair activation response.");
    }
    Ok(())
}

impl PairActivationProof {
    async fn activate(self) -> ResultType<()> {
        // The server accepts repeated reports for the same consumed ticket
        // without changing the activation time. Never retry a rejection.
        for attempt in 0..2 {
            match post_response("activate-pair", &self.token, &self.body).await {
                Ok((status, bytes)) if attempt == 1 || (status != 429 && !(500..600).contains(&status)) => {
                    return parse_activation_response(parse_response(status, &bytes)?);
                }
                Ok(_) => {}
                Err(error) if attempt == 0 && error.downcast_ref::<reqwest::Error>().is_some_and(|error| {
                    error.is_timeout() || error.is_connect() || error.is_request() || error.is_body()
                }) => {}
                Err(_) => bail!("Could not contact DogShare to activate this account pair. Connect again."),
            }
            tokio::time::sleep(ACTIVATION_RETRY_DELAY).await;
        }
        bail!("DogShare pair activation timed out. Connect again.");
    }
}

fn activation_required(value: &Value, supported: bool) -> ResultType<bool> {
    match value.get("activation_required") {
        None | Some(Value::Bool(false)) => Ok(false),
        Some(Value::Bool(true)) if supported => Ok(true),
        _ => bail!("Invalid DogShare connection activation response."),
    }
}

async fn mint_ticket(
    target: &str,
    kind: &str,
    allow_activation: bool,
) -> ResultType<(String, Option<PairActivationProof>)> {
    validate_device_id(target)?;
    let token = access_token()?;
    let identity = request_body()?;
    let mut body = identity.clone();
    body["target_id"] = json!(target);
    body["conn_type"] = json!(kind);
    let supported = allow_activation && crate::dogshare_role::is_controller() && kind == "remote";
    if supported {
        body["supports_pair_activation"] = json!(true);
    }
    let response = post("connection-ticket", &token, body).await?;
    let ticket = response["ticket"].as_str().unwrap_or_default();
    validate_ticket(ticket)?;
    if response["expires_at"].as_u64().unwrap_or(0) <= unix_now()? {
        bail!("DogShare connection authorization has expired.");
    }
    let proof = if activation_required(&response, supported)? {
        let mut body = identity;
        body["ticket"] = json!(ticket);
        body["target_id"] = json!(target);
        Some(PairActivationProof { token, body })
    } else {
        None
    };
    Ok((ticket.to_owned(), proof))
}

pub async fn require_connection(target: &str, kind: ConnType) -> ResultType<()> {
    if !cfg!(windows) {
        return Ok(());
    }
    validate_device_id(target)?;
    authorize_remote(&access_token()?).await?;
    // Reject an unbound destination before opening any peer connection. Actual
    // login attempts receive their own one-use ticket, including password retries.
    let _ = mint_ticket(target, connection_type(kind), true).await?;
    Ok(())
}

#[cfg(windows)]
pub(crate) async fn prepare_login(
    login: &mut LoginRequest,
    allow_activation: bool,
) -> ResultType<Option<PairActivationProof>> {
    if crate::dogshare_role::is_controller() {
        login.password.clear();
    }
    let (ticket, proof) = mint_ticket(&login.username, login_type(login), allow_activation).await?;
    login.dogshare_account_ticket = ticket;
    Ok(proof)
}

pub fn validate_ticket(ticket: &str) -> ResultType<()> {
    if !(32..=128).contains(&ticket.len())
        || !ticket
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    {
        bail!("Both devices must sign in with a DogShare account before connecting.");
    }
    Ok(())
}

async fn ticket_request(path: &str, login: &LoginRequest) -> ResultType<()> {
    validate_ticket(&login.dogshare_account_ticket)?;
    validate_device_id(&login.my_id)?;
    let token = access_token()?;
    ticket_request_with_token(path, login, &token).await
}

async fn ticket_request_with_token(path: &str, login: &LoginRequest, token: &str) -> ResultType<()> {
    let mut body = request_body()?;
    let target_id = body["id"].as_str().unwrap_or_default().to_owned();
    body["ticket"] = json!(login.dogshare_account_ticket);
    body["source_id"] = json!(login.my_id);
    body["conn_type"] = json!(login_type(login));
    let response = post(path, token, body).await?;
    if crate::dogshare_role::is_receiver()
        && (response["source"]["role"].as_str() != Some("controller")
            || response["target"]["role"].as_str() != Some("receiver"))
    {
        bail!("DogShare connection account roles are invalid.");
    }
    if response["authorized"].as_bool() != Some(true)
        || response["source"]["id"].as_str() != Some(login.my_id.as_str())
        || response["target"]["id"].as_str() != Some(target_id.as_str())
    {
        bail!("DogShare connection authorization is invalid.");
    }
    Ok(())
}

pub async fn consume_ticket(login: &LoginRequest) -> ResultType<()> {
    if !cfg!(windows) {
        return Ok(());
    }
    ticket_request("consume-ticket", login).await
}

pub async fn check_connection(login: &LoginRequest) -> ResultType<()> {
    if !cfg!(windows) {
        return Ok(());
    }
    ticket_request("connection-status", login).await
}

#[cfg(windows)]
pub(crate) async fn check_voice_connection(login: &LoginRequest) -> ResultType<()> {
    validate_ticket(&login.dogshare_account_ticket)?;
    validate_device_id(&login.my_id)?;
    let token = access_token()?;
    if !crate::dogshare_credentials::has_voice_consent(&token) {
        bail!("DogShare B must sign in again to receive voice calls.");
    }
    ticket_request_with_token("connection-status", login, &token).await?;
    if access_token()? != token || !crate::dogshare_credentials::has_voice_consent(&token) {
        bail!("DogShare B sign-in changed during voice authorization.");
    }
    Ok(())
}

pub fn invalidate() {
    let mut lease = LEASE.lock().unwrap();
    lease.generation = lease.generation.wrapping_add(1);
    lease.deadline = None;
    lease.expires_at = 0;
    lease.user = None;
    lease.error = SIGN_IN_REQUIRED.to_owned();
    drop(lease);
    close_outgoing_sessions();
}

fn fail_refresh(generation: u64, error: String) {
    let mut lease = LEASE.lock().unwrap();
    if lease.generation != generation {
        return;
    }
    lease.generation = lease.generation.wrapping_add(1);
    lease.deadline = None;
    lease.expires_at = 0;
    lease.user = None;
    lease.error = error;
    drop(lease);
    close_outgoing_sessions();
}

fn close_outgoing_sessions() {
    #[cfg(all(windows, feature = "flutter"))]
    {
        use crate::client::{Data, Interface};
        let sessions = crate::flutter::sessions::get_sessions();
        for session in sessions {
            session.send(Data::Close);
        }
    }
}

fn snapshot() -> Value {
    let lease = LEASE.lock().unwrap();
    let authorized = lease
        .deadline
        .map_or(false, |deadline| Instant::now() < deadline);
    if authorized {
        json!({"authorized": true, "error": "", "expires_at": lease.expires_at, "user": lease.user})
    } else {
        let error = if lease.error.is_empty() {
            "DogShare account verification expired. Sign in again."
        } else {
            lease.error.as_str()
        };
        json!({"authorized": false, "error": error, "expires_at": 0})
    }
}

fn refresh_blocking(generation: u64) -> ResultType<()> {
    use std::io::Read;
    let token = access_token()?;
    let mut body = request_body()?;
    let action = if crate::dogshare_role::is_controller() { "remote" } else { "subtitles" };
    body["action"] = json!(action);
    let client = reqwest::blocking::Client::builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(HTTP_TIMEOUT)
        .build()?;
    let response = client
        .post(format!("{API_SERVER}/api/dogshare/authorize"))
        .bearer_auth(&token)
        .json(&body)
        .send()?;
    let status = response.status().as_u16();
    let mut bytes = Vec::new();
    response
        .take((RESPONSE_LIMIT + 1) as u64)
        .read_to_end(&mut bytes)?;
    let now = unix_now()?;
    let authorization = parse_authorization(parse_response(status, &bytes)?, action, now)?;
    let fresh_token = crate::dogshare_credentials::read_access_token();
    let mut lease = LEASE.lock().unwrap();
    if lease.generation != generation || fresh_token != token {
        bail!("DogShare account changed during verification. Retry sign-in.");
    }
    let seconds = OVERLAY_LEASE.as_secs().min(authorization.expires_at - now);
    lease.deadline = Some(Instant::now() + Duration::from_secs(seconds));
    lease.expires_at = now + seconds;
    lease.user = Some(authorization.user);
    lease.error.clear();
    Ok(())
}

fn json_pointer(value: Value) -> *mut c_char {
    CString::new(value.to_string())
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn dogshare_account_refresh() -> *mut c_char {
    // This ABI is called on a Dart worker isolate. Keep reqwest's blocking
    // runtime on a dedicated thread even if another caller has a Tokio context.
    let generation = LEASE.lock().unwrap().generation;
    let result = std::thread::Builder::new()
        .name("dogshare-account".to_owned())
        .spawn(move || refresh_blocking(generation))
        .map_err(|_| anyhow!("Unable to start DogShare account verification."))
        .and_then(|thread| {
            thread
                .join()
                .unwrap_or_else(|_| Err(anyhow!("DogShare account verification failed.")))
        });
    if let Err(error) = result {
        fail_refresh(generation, error.to_string());
    }
    json_pointer(snapshot())
}

#[no_mangle]
pub extern "C" fn dogshare_account_snapshot() -> *mut c_char {
    json_pointer(snapshot())
}

#[no_mangle]
pub unsafe extern "C" fn dogshare_account_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[no_mangle]
pub extern "C" fn dogshare_account_overlay_allowed() -> bool {
    if crate::dogshare_role::is_controller() {
        return false;
    }
    LEASE
        .lock()
        .map(|lease| {
            lease
                .deadline
                .map_or(false, |deadline| Instant::now() < deadline)
        })
        .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn dogshare_account_invalidate() {
    invalidate();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn negotiates_activation_only_when_explicitly_requested_by_server() {
        assert!(!activation_required(&json!({}), true).unwrap());
        assert!(!activation_required(&json!({"activation_required": false}), true).unwrap());
        assert!(activation_required(&json!({"activation_required": true}), true).unwrap());
        assert!(activation_required(&json!({"activation_required": true}), false).is_err());
        assert!(activation_required(&json!({"activation_required": "true"}), true).is_err());
        assert!(parse_activation_response(json!({"activated": true, "expires_at": 1000})).is_ok());
        assert!(parse_activation_response(json!({"activated": true})).is_err());
        assert!(parse_activation_response(json!({"activated": false, "expires_at": 1000})).is_err());
    }

    #[test]
    fn rejects_direct_addresses_and_missing_ticket_proof() {
        for id in [
            "",
            "127.0.0.1",
            "192.0.2.1:21118",
            "host.example:21118",
            "123@other-server",
        ] {
            assert!(validate_device_id(id).is_err(), "{id}");
        }
        assert!(validate_device_id("100000001").is_ok());
        assert!(validate_ticket("").is_err());
        assert!(validate_ticket(&"x".repeat(129)).is_err());
        assert!(validate_ticket(&"x".repeat(43)).is_ok());
        assert_eq!(connection_type(ConnType::RDP), "port_forward");
    }

    #[test]
    fn stale_refresh_failure_preserves_a_new_login() {
        invalidate();
        let stale_generation = LEASE.lock().unwrap().generation;
        invalidate();
        {
            let mut lease = LEASE.lock().unwrap();
            lease.deadline = Some(Instant::now() + OVERLAY_LEASE);
            lease.expires_at = 1000;
            lease.user = Some(json!({"name": "new-user"}));
        }
        fail_refresh(stale_generation, "Old request failed".to_owned());
        assert_eq!(dogshare_account_overlay_allowed(), !crate::dogshare_role::is_controller());
        assert_eq!(snapshot()["user"]["name"], "new-user");
        invalidate();
    }

    #[test]
    fn account_permission_requires_current_server_proof() {
        let valid = json!({"expires_at": 1000, "user": {"name": "alice", "status": 1, "role": crate::dogshare_role::account_role()}, "permissions": {"remote": true, "subtitles": true}});
        assert!(parse_authorization(valid.clone(), "remote", 999).is_ok());
        assert!(parse_authorization(valid.clone(), "remote", 1000).is_err());
        let mut disabled = valid;
        disabled["user"]["status"] = json!(0);
        assert!(parse_authorization(disabled, "subtitles", 999).is_err());
        assert!(parse_response(401, b"{\"authorized\":true}").is_err());
        assert!(parse_authorization(json!({"user": {"name": "alice"}}), "remote", 1).is_err());
    }
}
