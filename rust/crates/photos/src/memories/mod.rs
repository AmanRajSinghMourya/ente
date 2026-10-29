mod calendar;
mod filler;
mod input;
mod on_this_day;
mod output;
mod photo;
mod rng;
mod selector;
mod time;

use std::collections::HashSet;

pub use calendar::LocalDate;
pub use input::{MemoriesRequest, MemoryFile, Period, PhotoSignals};
pub use output::{Memory, MemoryKind, TimeMemory};

use photo::Photo;
use selector::Selector;

const UPDATE_FREQUENCY_DAYS: i64 = 3;
const MAX_MEMORY_ITEMS: usize = 100;
const MINIMUM_MEMORY_LENGTH: usize = 5;

pub fn compute_smart_memories(
    request: &MemoriesRequest,
    periods: &[Period],
    signals: Option<&dyn PhotoSignals>,
) -> Vec<Vec<Memory>> {
    let photos = photo::prepare(&request.files);
    let excluded_collection_ids: HashSet<i64> =
        request.excluded_collection_ids.iter().copied().collect();
    let mut selector = Selector::new(signals, request.seed);
    periods
        .iter()
        .map(|&period| {
            let mut memories =
                on_this_day::memories(&photos, period, &excluded_collection_ids, &mut selector);
            let time_memories = time::memories(
                &unused_photos(&photos, &memories),
                &photos,
                period,
                &mut selector,
            );
            memories.extend(time_memories);
            let filler_memories = filler::memories(&unused_photos(&photos, &memories), period);
            memories.extend(filler_memories);
            memories
        })
        .collect()
}

pub fn compute_simple_memories(request: &MemoriesRequest, period: Period) -> Vec<Memory> {
    let photos = photo::prepare(&request.files);
    let excluded_collection_ids: HashSet<i64> =
        request.excluded_collection_ids.iter().copied().collect();
    let mut selector = Selector::new(None, request.seed);
    let mut memories: Vec<Memory> =
        on_this_day::memories(&photos, period, &excluded_collection_ids, &mut selector)
            .into_iter()
            .take(1)
            .filter(|memory| memory.is_shown_at(period.now))
            .collect();
    let filler_memories = filler::memories(&unused_photos(&photos, &memories), period);
    memories.extend(filler_memories);
    memories
}

fn unused_photos<'p>(
    photos: impl IntoIterator<Item = &'p Photo>,
    memories: &[Memory],
) -> Vec<&'p Photo> {
    let used: HashSet<i64> = memories
        .iter()
        .flat_map(|memory| memory.file_ids.iter().copied())
        .collect();
    photos
        .into_iter()
        .filter(|photo| !used.contains(&photo.id))
        .collect()
}

#[cfg(test)]
mod tests {
    use ente_exif::DateTime;

    use super::{
        MemoriesRequest, Memory, MemoryFile, MemoryKind, Period, TimeMemory,
        compute_simple_memories, compute_smart_memories,
    };

    pub(super) fn micros(date_time: &str) -> i64 {
        DateTime::parse(&format!("{date_time}Z"))
            .and_then(DateTime::unix_micros)
            .unwrap()
    }

    pub(super) fn file(id: i64, date_time: &str) -> MemoryFile {
        MemoryFile {
            id,
            creation_time: micros(date_time),
            local_date_time: None,
            utc_offset_seconds: 0,
            collection_id: None,
        }
    }

    pub(super) fn files_on(first_id: i64, date: &str, count: i64) -> Vec<MemoryFile> {
        (0..count)
            .map(|index| {
                let minutes = 8 * 60 + index * 20;
                file(
                    first_id + index,
                    &format!("{date}T{:02}:{:02}:00", minutes / 60, minutes % 60),
                )
            })
            .collect()
    }

    pub(super) fn period(date_time: &str) -> Period {
        Period {
            now: micros(date_time),
            utc_offset_seconds: 0,
        }
    }

    fn kinds(memories: &[Memory]) -> Vec<MemoryKind> {
        memories.iter().map(|memory| memory.kind).collect()
    }

    fn library() -> Vec<MemoryFile> {
        let background_start = micros("2019-03-01T00:00:00");
        let mut files: Vec<MemoryFile> = (0..1500)
            .map(|index| MemoryFile {
                creation_time: background_start + index * 20 * 60_000_000,
                ..file(1000 + index, "2019-03-01T00:00:00")
            })
            .collect();
        files.extend(files_on(1, "2023-10-30", 3));
        files.extend(files_on(10, "2021-10-30", 3));
        files.extend(files_on(20, "2024-11-01", 1));
        files.extend(files_on(30, "2026-10-20", 6));
        files
    }

    fn request() -> MemoriesRequest {
        MemoriesRequest {
            files: library(),
            excluded_collection_ids: Vec::new(),
            seed: 3,
        }
    }

    #[test]
    fn each_period_runs_on_this_day_then_time_then_fillers_without_reusing_photos() {
        let periods = compute_smart_memories(
            &request(),
            &[period("2026-10-30T09:00:00"), period("2026-11-02T09:00:00")],
            None,
        );

        let current = &periods[0];
        assert_eq!(
            kinds(current),
            [
                MemoryKind::OnThisDay,
                MemoryKind::Time(TimeMemory::LastWeek),
                MemoryKind::Filler { years_ago: 2 },
            ]
        );
        assert_eq!(current[0].file_ids, [10, 11, 12, 1, 2, 3]);
        assert_eq!(current[1].file_ids, [30, 31, 32, 33, 34, 35]);
        assert_eq!(current[2].file_ids, [20]);

        let next = &periods[1];
        assert_eq!(
            kinds(next),
            [
                MemoryKind::Time(TimeMemory::LastMonth),
                MemoryKind::Time(TimeMemory::Week { years_ago: Some(3) }),
                MemoryKind::Time(TimeMemory::Week { years_ago: Some(5) }),
                MemoryKind::Time(TimeMemory::Month {
                    year: 2024,
                    month: 11,
                    years_ago: Some(2),
                }),
            ]
        );
        assert_eq!(next[0].first_date_to_show, micros("2026-11-01T00:00:00"));
        assert_eq!(next[0].last_date_to_show, micros("2026-12-01T00:00:00"));
    }

    #[test]
    fn simple_memories_keep_on_this_day_only_when_it_shows_today() {
        let today = compute_simple_memories(&request(), period("2026-10-30T09:00:00"));
        assert_eq!(
            kinds(&today),
            [MemoryKind::OnThisDay, MemoryKind::Filler { years_ago: 2 }]
        );

        let day_before = compute_simple_memories(&request(), period("2026-10-29T09:00:00"));
        assert_eq!(
            kinds(&day_before),
            [
                MemoryKind::Filler { years_ago: 3 },
                MemoryKind::Filler { years_ago: 5 },
            ]
        );
    }

    #[test]
    fn memories_hold_at_most_one_hundred_photos() {
        let request = MemoriesRequest {
            files: (0..150)
                .map(|index| {
                    file(
                        index,
                        &format!("2020-10-29T{:02}:{:02}:00", index / 60, index % 60),
                    )
                })
                .collect(),
            excluded_collection_ids: Vec::new(),
            seed: 0,
        };

        let memories = compute_simple_memories(&request, period("2026-10-28T09:00:00"));

        assert_eq!(kinds(&memories), [MemoryKind::Filler { years_ago: 6 }]);
        assert_eq!(memories[0].file_ids, (0..100).collect::<Vec<_>>());
    }
}
