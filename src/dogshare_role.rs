use base::{config::keys, message_proto::LoginRequest};
use hbb_common::{bail, config, rendezvous_proto::ConnType, ResultType};

#[cfg(all(feature = "dogshare-controller", feature = "dogshare-receiver"))]
compile_error!("DogShare controller and receiver features are mutually exclusive.");

pub const fn account_role() -> Option<&'static str> {
    if cfg!(all(windows, feature = "dogshare-controller")) {
        Some("controller")
    } else if cfg!(all(windows, feature = "dogshare-receiver")) {
        Some("receiver")
    } else {
        None
    }
}

pub const fn is_controller() -> bool {
    cfg!(all(windows, feature = "dogshare-controller"))
}

pub const fn is_receiver() -> bool {
    cfg!(all(windows, feature = "dogshare-receiver"))
}

pub const fn is_split() -> bool {
    is_controller() || is_receiver()
}

pub const ID_SERVER: &str = "phenoseed.com:21116";
pub const RELAY_SERVER: &str = "phenoseed.com:21117";
pub const SERVER_KEY: &str = "qB3gToeF8XffSp+r8ShbZy2h8JCsWVaJAu9d3uWlmNc=";

pub fn require_user_session() -> ResultType<()> {
    #[cfg(windows)]
    if is_split() && crate::platform::is_root() {
        bail!("DogShare A/B must run as the signed-in Windows user, not as SYSTEM.");
    }
    Ok(())
}

pub fn initialize() -> ResultType<()> {
    if !is_split() {
        return Ok(());
    }
    require_user_session()?;
    {
        let mut settings = config::OVERWRITE_SETTINGS.write().unwrap();
        for (key, value) in [
            (keys::OPTION_CUSTOM_RENDEZVOUS_SERVER, ID_SERVER),
            (keys::OPTION_RELAY_SERVER, RELAY_SERVER),
            (keys::OPTION_KEY, SERVER_KEY),
            (keys::OPTION_ALLOW_WEBSOCKET, "N"),
        ] {
            settings.insert(key.to_owned(), value.to_owned());
        }
    }
    *config::EXE_RENDEZVOUS_SERVER.write().unwrap() = ID_SERVER.to_owned();
    config::HARD_SETTINGS
        .write()
        .unwrap()
        .insert("disable-installation".to_owned(), "Y".to_owned());
    Ok(())
}

pub fn is_incoming_only() -> bool {
    if is_split() {
        is_receiver()
    } else {
        config::is_incoming_only()
    }
}

pub fn is_outgoing_only() -> bool {
    if is_split() {
        is_controller()
    } else {
        config::is_outgoing_only()
    }
}

pub fn require_outgoing(kind: ConnType) -> ResultType<()> {
    if is_receiver() {
        bail!("DogShare B cannot start remote connections.");
    }
    if is_controller() && !matches!(kind, ConnType::DEFAULT_CONN | ConnType::VIEW_CAMERA) {
        bail!("DogShare A supports remote desktop and paired camera connections only.");
    }
    Ok(())
}

pub fn require_incoming(login: &LoginRequest) -> ResultType<()> {
    if is_controller() {
        bail!("DogShare A does not accept remote connections.");
    }
    if is_receiver() && login.union.is_some() && !login.has_view_camera() {
        bail!("DogShare B accepts remote desktop and paired camera connections only.");
    }
    Ok(())
}

pub fn require_account_role(role: Option<&str>) -> ResultType<()> {
    if let Some(expected) = account_role() {
        if role != Some(expected) {
            bail!("This DogShare edition requires a {} account.", expected);
        }
    }
    Ok(())
}

pub fn blocks_permission(key: &str) -> bool {
    is_receiver()
        && matches!(
            key,
            keys::OPTION_ENABLE_FILE_TRANSFER
                | keys::OPTION_ENABLE_TERMINAL
                | keys::OPTION_ENABLE_TUNNEL
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dogshare_role_limits_connection_directions_and_types() {
        assert_eq!(
            require_outgoing(ConnType::DEFAULT_CONN).is_ok(),
            !is_receiver()
        );
        assert_eq!(
            require_outgoing(ConnType::VIEW_CAMERA).is_ok(),
            !is_receiver()
        );
        for kind in [
            ConnType::FILE_TRANSFER,
            ConnType::TERMINAL,
            ConnType::PORT_FORWARD,
            ConnType::RDP,
        ] {
            assert_eq!(require_outgoing(kind).is_ok(), !is_split());
        }
        let mut login = LoginRequest::new();
        assert_eq!(require_incoming(&login).is_ok(), !is_controller());
        login.set_view_camera(Default::default());
        assert_eq!(require_incoming(&login).is_ok(), !is_controller());
        login.set_file_transfer(Default::default());
        assert_eq!(require_incoming(&login).is_ok(), !is_split());
    }

    #[test]
    fn dogshare_role_requires_matching_server_account() {
        assert_eq!(require_account_role(None).is_ok(), !is_split());
        for role in ["controller", "receiver"] {
            assert_eq!(
                require_account_role(Some(role)).is_ok(),
                account_role().map_or(true, |expected| expected == role)
            );
        }
    }

    #[test]
    fn dogshare_receiver_blocks_file_clipboard_but_preserves_text_and_audio() {
        assert_eq!(
            blocks_permission(keys::OPTION_ENABLE_FILE_TRANSFER),
            is_receiver()
        );
        assert!(!blocks_permission(keys::OPTION_ENABLE_CLIPBOARD));
        assert!(!blocks_permission(keys::OPTION_ENABLE_AUDIO));
    }
}
