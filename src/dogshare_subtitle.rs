//! Validated snapshots on the paired Windows remote desktop channel.

use base::message_proto::{Message, Misc, DogShareSubtitle};
use serde_derive::{Deserialize, Serialize};

// A reserved input to the existing Flutter bridge. Never write it to peer settings.
#[cfg(feature = "flutter")]
pub const BRIDGE_COMMAND: &str = "dogshare-runtime-subtitle-frame";

const MAX_TEXT_UNITS: usize = 2000;
const MAX_JSON_BYTES: usize = 16 * 1024;

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Frame {
    enabled: bool,
    text: String,
    font_size: f32,
    font_family: String,
    color: u32,
}

impl Frame {
    fn is_valid(&self) -> bool {
        (8.0..=96.0).contains(&self.font_size)
            && self.text.len() <= MAX_TEXT_UNITS * 3
            && !self.text.contains('\0')
            && self.text.encode_utf16().count() <= MAX_TEXT_UNITS
            && matches!(
                self.font_family.as_str(),
                "Microsoft YaHei" | "SimHei" | "SimSun" | "Segoe UI" | "Arial" | "Consolas"
            )
    }
}

pub fn from_ui_json(json: &str) -> Option<Message> {
    if json.len() > MAX_JSON_BYTES {
        return None;
    }
    let frame: Frame = serde_json::from_str(json).ok()?;
    if !frame.is_valid() {
        return None;
    }
    let mut misc = Misc::new();
    misc.set_dogshare_subtitle(DogShareSubtitle {
        enabled: frame.enabled,
        text: frame.text,
        font_size: frame.font_size,
        font_family: frame.font_family,
        color: frame.color,
        ..Default::default()
    });
    let mut message = Message::new();
    message.set_misc(misc);
    Some(message)
}

pub fn to_ui_json(wire: DogShareSubtitle) -> Option<String> {
    let frame = Frame {
        enabled: wire.enabled,
        text: wire.text,
        font_size: wire.font_size,
        font_family: wire.font_family,
        color: wire.color,
    };
    if !frame.is_valid() {
        return None;
    }
    serde_json::to_string(&frame).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::{message, misc};

    #[test]
    fn round_trip_preserves_live_subtitle_and_clear_snapshots() {
        for (enabled, text) in [(true, "实时字幕 🎬\n下一行"), (true, ""), (false, "")] {
            let json = serde_json::json!({
                "enabled": enabled, "text": text, "fontSize": 16.5,
                "fontFamily": "Microsoft YaHei", "color": 0x7f_dd_dd_dd_u32,
            });
            let msg = from_ui_json(&json.to_string()).unwrap();
            let Some(message::Union::Misc(misc)) = msg.union else {
                panic!("expected dedicated misc message");
            };
            let Some(misc::Union::DogshareSubtitle(frame)) = misc.union else {
                panic!("expected dedicated subtitle frame");
            };
            let decoded: serde_json::Value =
                serde_json::from_str(&to_ui_json(frame).unwrap()).unwrap();
            assert_eq!(decoded, json);
        }
    }

    #[test]
    fn invalid_snapshots_are_rejected_at_both_ends() {
        let oversized = "🎬".repeat(1001);
        for (font_size, font_family, text) in [
            (97.0, "Microsoft YaHei", ""),
            (16.0, "file:///bad-font", ""),
            (16.0, "Segoe UI", oversized.as_str()),
            (16.0, "Arial", "invalid\0text"),
        ] {
            let json = serde_json::json!({
                "enabled": true, "text": text, "fontSize": font_size,
                "fontFamily": font_family, "color": 0xff_dd_dd_dd_u32,
            });
            assert!(from_ui_json(&json.to_string()).is_none());
            assert!(to_ui_json(DogShareSubtitle {
                enabled: true,
                text: text.to_owned(),
                font_size,
                font_family: font_family.to_owned(),
                color: 0xff_dd_dd_dd,
                ..Default::default()
            }).is_none());
        }
    }
}
