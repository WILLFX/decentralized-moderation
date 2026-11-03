//! Client usage policy, independent of contract identity and on-chain permissions.
use crate::CoreError;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProfilePurpose {
    #[default]
    Standard,
    ExistingWork,
}

impl ProfilePurpose {
    pub fn is_standard(&self) -> bool {
        *self == Self::Standard
    }

    /// This only checks profile policy; existing action and contract checks remain required.
    pub fn check_publication(self, action: &str) -> Result<(), CoreError> {
        if self == Self::ExistingWork && matches!(action, "approve" | "submit") {
            Err(CoreError("EXISTING_WORK_ONLY"))
        } else {
            Ok(())
        }
    }

    pub fn check_staking(self, action: &str) -> Result<(), CoreError> {
        if self == Self::ExistingWork && matches!(action, "approveStake" | "stake") {
            Err(CoreError("EXISTING_WORK_ONLY"))
        } else {
            Ok(())
        }
    }
}
