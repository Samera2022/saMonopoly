use serde::{Deserialize, Serialize};

use crate::types::TileId;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MovementResult {
    pub from: TileId,
    pub to: TileId,
    pub passed_start: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_movement_result_creation() {
        let result = MovementResult {
            from: "GO".to_string(),
            to: "Mediterranean".to_string(),
            passed_start: true,
        };
        assert_eq!(result.from, "GO");
        assert_eq!(result.to, "Mediterranean");
        assert!(result.passed_start);

        let result_no_pass = MovementResult {
            from: "Mediterranean".to_string(),
            to: "Baltic".to_string(),
            passed_start: false,
        };
        assert_eq!(result_no_pass.from, "Mediterranean");
        assert_eq!(result_no_pass.to, "Baltic");
        assert!(!result_no_pass.passed_start);
    }
}
