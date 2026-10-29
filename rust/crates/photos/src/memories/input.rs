use super::calendar::{LocalDate, MICROS_PER_DAY, MICROS_PER_SECOND};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MemoryFile {
    pub id: i64,
    pub creation_time: i64,
    pub local_date_time: Option<String>,
    pub utc_offset_seconds: i32,
    pub collection_id: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MemoriesRequest {
    pub files: Vec<MemoryFile>,
    pub excluded_collection_ids: Vec<i64>,
    pub seed: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Period {
    pub now: i64,
    pub utc_offset_seconds: i32,
}

impl Period {
    fn local_now(self) -> i64 {
        self.now + self.utc_offset_micros()
    }

    pub(super) fn today(self) -> LocalDate {
        LocalDate::of_local_time(self.local_now())
    }

    pub(super) fn start_of(self, date: LocalDate) -> i64 {
        date.days_since_epoch() * MICROS_PER_DAY - self.utc_offset_micros()
    }

    fn utc_offset_micros(self) -> i64 {
        i64::from(self.utc_offset_seconds) * MICROS_PER_SECOND
    }
}

pub trait PhotoSignals {
    fn face_weight(&self, file_id: i64) -> u32;
    fn nostalgia(&self, file_id: i64) -> Option<f32>;
    fn similarity(&self, file_id: i64, other_file_id: i64) -> Option<f32>;
}
