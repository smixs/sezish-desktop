use serde::Serialize;
use thiserror::Error;

#[derive(Debug, Error, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum AppError {
    #[error("{message}")]
    InvalidInput { message: String },
    #[error("{message}")]
    Busy { message: String },
    #[error("{message}")]
    NotReady { message: String },
    #[error("{message}")]
    Platform { message: String },
    #[error("{message}")]
    Internal { message: String },
}

impl AppError {
    pub fn invalid(message: impl Into<String>) -> Self {
        Self::InvalidInput {
            message: message.into(),
        }
    }

    pub fn busy(message: impl Into<String>) -> Self {
        Self::Busy {
            message: message.into(),
        }
    }

    pub fn not_ready(message: impl Into<String>) -> Self {
        Self::NotReady {
            message: message.into(),
        }
    }

    pub fn platform(message: impl Into<String>) -> Self {
        Self::Platform {
            message: message.into(),
        }
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self::Internal {
            message: message.into(),
        }
    }
}

impl From<std::io::Error> for AppError {
    fn from(error: std::io::Error) -> Self {
        Self::internal(error.to_string())
    }
}

impl From<sez_core::SezError> for AppError {
    fn from(error: sez_core::SezError) -> Self {
        Self::internal(error.to_string())
    }
}
