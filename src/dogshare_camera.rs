use base::message_proto::{LoginRequest, PeerInfo};
use hbb_common::{
    bytes::Bytes,
    rand::{rngs::OsRng, RngCore},
    sodiumoxide::crypto::auth,
    ResultType,
};

pub const NEED_PARENT: &str = "Connect to the paired desktop before opening its camera";
pub type Key = [u8; auth::KEYBYTES];

#[cfg(all(windows, feature = "flutter"))]
pub fn desktop_window_token(
    session: &crate::flutter::FlutterSession,
    id: crate::flutter_ffi::SessionID,
) -> Option<String> {
    desktop_key(session).map(|_| id.to_string())
}

#[cfg(all(windows, feature = "flutter"))]
pub fn resolve_desktop_key(peer: &str, window_token: Option<&str>) -> Option<Key> {
    use crate::{client::Interface, flutter::sessions, flutter_ffi::SessionID};
    let id = SessionID::parse_str(window_token?).ok()?;
    let session = sessions::get_session_by_session_id(&id)?;
    if session.get_id() != peer {
        return None;
    }
    desktop_key(&session)
}

#[cfg(all(windows, feature = "flutter"))]
fn desktop_key(session: &crate::flutter::FlutterSession) -> Option<Key> {
    if !session.is_default()
        || !session
            .connection_round_state
            .lock()
            .unwrap()
            .is_connected()
    {
        return None;
    }
    session.lc.read().unwrap().dogshare_camera_key
}

pub fn random_key() -> ResultType<Key> {
    let mut key = [0; auth::KEYBYTES];
    OsRng.try_fill_bytes(&mut key)?;
    Ok(key)
}

pub fn proof(key: &Key, challenge: &[u8]) -> Bytes {
    if challenge.len() != auth::KEYBYTES {
        return Bytes::new();
    }
    Bytes::copy_from_slice(&auth::authenticate(challenge, &auth::Key(*key)).0)
}

pub fn has_proof(login: &LoginRequest) -> bool {
    login.has_view_camera()
        && login.view_camera().dogshare_parent_proof.len() == auth::TAGBYTES
        && login.dogshare_account_ticket.is_empty()
}

pub fn take_controller_key<T: crate::ui_session_interface::InvokeUiSession>(
    session: &crate::ui_session_interface::Session<T>,
    stream: &hbb_common::Stream,
    info: &mut PeerInfo,
) {
    // PeerInfo is used by the UI and logged. Keep the key in native session memory.
    let key = std::mem::take(&mut info.dogshare_camera_key);
    #[cfg(windows)]
    if crate::dogshare_role::is_controller() && session.is_default() {
        session.lc.write().unwrap().dogshare_camera_key = if stream.is_secured() {
            key.as_ref().try_into().ok()
        } else {
            None
        };
    }
    #[cfg(not(windows))]
    let _ = (session, stream, key);
}

pub struct Parent {
    pub key: Key,
    account_ticket: String,
}

impl Parent {
    pub fn new(account_ticket: String) -> ResultType<Self> {
        Ok(Self {
            key: random_key()?,
            account_ticket,
        })
    }

    fn matches(&self, challenge: &[u8], proof: &[u8]) -> bool {
        challenge.len() == auth::KEYBYTES
            && auth::Tag::from_slice(proof)
                .is_some_and(|tag| auth::verify(&tag, challenge, &auth::Key(self.key)))
    }

    pub fn desktop_login(
        &self,
        peer_id: &str,
        challenge: &[u8],
        proof: &[u8],
    ) -> Option<LoginRequest> {
        if !self.matches(challenge, proof) {
            return None;
        }
        Some(LoginRequest {
            my_id: peer_id.to_owned(),
            dogshare_account_ticket: self.account_ticket.clone(),
            ..Default::default()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opening_requires_a_proof_from_the_matching_desktop() {
        let parent = Parent::new("desktop-ticket".into()).unwrap();
        let another = Parent::new("another-desktop-ticket".into()).unwrap();
        let challenge = random_key().unwrap();
        let different_challenge = random_key().unwrap();
        let proof = proof(&parent.key, &challenge);
        assert!(another.desktop_login("device", &challenge, &proof).is_none());
        assert!(parent.desktop_login("device", &different_challenge, &proof).is_none());
        let desktop = parent.desktop_login("device", &challenge, &proof).unwrap();
        assert_eq!(desktop.dogshare_account_ticket, "desktop-ticket");
        assert_eq!(desktop.my_id, "device");
    }
}
