use std::cmp::Reverse;
use std::collections::{HashMap, HashSet};
use std::ops::Range;

use super::fill::decode_centroid;
use super::{CLUSTER_CENTROID_DIMENSIONS, Error, MlStore, Result};
use crate::face_clustering::{ClusterMean, Face, IncrementalFace, cluster_incrementally};
use crate::ml_db::ClusterSummary;
use crate::ml_db::vector_encoding::encode_evector;

const BUCKET_SIZE: usize = 10_000;
const BUCKET_STEP: usize = 7_500;

pub struct FaceClusteringRequest {
    pub file_creation_times: HashMap<i64, i64>,
    pub rejected_cluster_ids: HashMap<String, HashSet<String>>,
    pub distance_threshold: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FaceClusteringPlan {
    pub faces: usize,
    pub unclustered_faces: usize,
    pub missing_files: usize,
    pub invalid_faces: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ClusteredBucket {
    pub clustered_faces: usize,
    pub processed_faces: usize,
}

pub struct FaceClusteringRun {
    faces: Vec<IncrementalFace>,
    cluster_means: HashMap<String, ClusterMean>,
    distance_threshold: f64,
    plan: FaceClusteringPlan,
    next_offset: Option<usize>,
    bucket_size: usize,
    bucket_step: usize,
}

impl FaceClusteringRun {
    pub fn plan(&self) -> FaceClusteringPlan {
        self.plan
    }

    fn next_bucket(&mut self) -> Option<Range<usize>> {
        while let Some(offset) = self.next_offset {
            let end = (offset + self.bucket_size).min(self.faces.len());
            self.next_offset = (end < self.faces.len()).then_some(offset + self.bucket_step);
            if self.faces[offset..end]
                .iter()
                .any(|face| face.cluster_id.is_none())
            {
                return Some(offset..end);
            }
        }
        None
    }

    fn record(&mut self, bucket: Range<usize>, assignments: &HashMap<String, String>) {
        for face in &mut self.faces[bucket] {
            if face.cluster_id.is_none() {
                face.cluster_id = assignments.get(&face.face.face_id).cloned();
            }
        }
    }
}

impl MlStore {
    pub fn start_face_clustering(
        &self,
        mut request: FaceClusteringRequest,
    ) -> Result<FaceClusteringRun> {
        if !request.distance_threshold.is_finite() {
            return Err(Error::InvalidArgument(format!(
                "face clustering distance threshold {} is not finite",
                request.distance_threshold
            )));
        }
        let mut faces = Vec::new();
        let mut missing_files = HashSet::new();
        let mut invalid_faces = 0;
        for face in self.db.get_faces_for_clustering()? {
            let Some(&creation_time) = request.file_creation_times.get(&face.file_id) else {
                missing_files.insert(face.file_id);
                continue;
            };
            let Some(embedding) = face.embedding.filter(|embedding| is_clusterable(embedding))
            else {
                invalid_faces += 1;
                continue;
            };
            let rejected_cluster_ids = request
                .rejected_cluster_ids
                .remove(&face.face_id)
                .unwrap_or_default();
            faces.push(IncrementalFace {
                face: Face {
                    face_id: face.face_id,
                    embedding,
                    creation_time: Some(creation_time),
                },
                cluster_id: face.cluster_id,
                bad: face.bad,
                rejected_cluster_ids,
            });
        }
        let missing_files: Vec<i64> = missing_files.into_iter().collect();
        self.db
            .delete_unclustered_face_index_for_files(&missing_files)?;
        faces.sort_by_key(|face| Reverse(face.face.creation_time));

        let unclustered_faces = faces
            .iter()
            .filter(|face| face.cluster_id.is_none())
            .count();
        let cluster_means = if unclustered_faces == 0 {
            HashMap::new()
        } else {
            self.cluster_means()?
        };
        Ok(FaceClusteringRun {
            plan: FaceClusteringPlan {
                faces: faces.len(),
                unclustered_faces,
                missing_files: missing_files.len(),
                invalid_faces,
            },
            next_offset: (unclustered_faces > 0).then_some(0),
            faces,
            cluster_means,
            distance_threshold: request.distance_threshold,
            bucket_size: BUCKET_SIZE,
            bucket_step: BUCKET_STEP,
        })
    }

    pub fn cluster_next_bucket(
        &self,
        run: &mut FaceClusteringRun,
    ) -> Result<Option<ClusteredBucket>> {
        let Some(bucket) = run.next_bucket() else {
            return Ok(None);
        };
        let clustering = cluster_incrementally(
            run.faces[bucket.clone()].to_vec(),
            run.distance_threshold,
            &run.cluster_means,
        );
        let summary: HashMap<String, ClusterSummary> = clustering
            .means
            .iter()
            .map(|(cluster_id, mean)| (cluster_id.clone(), cluster_summary(mean)))
            .collect();
        let written = self.assign_face_clusters(&clustering.assignments, &summary);
        if let Ok(()) | Err(Error::Index(_)) = written {
            run.record(bucket.clone(), &clustering.assignments);
            run.cluster_means.extend(clustering.means);
        }
        written.map(|()| {
            Some(ClusteredBucket {
                clustered_faces: clustering.assignments.len(),
                processed_faces: bucket.end,
            })
        })
    }

    fn cluster_means(&self) -> Result<HashMap<String, ClusterMean>> {
        Ok(self
            .db
            .get_all_cluster_summary(None)?
            .into_iter()
            .filter_map(|(cluster_id, summary)| {
                let mean = decode_centroid(&cluster_id, &summary.avg)?;
                let count = usize::try_from(summary.count).ok()?;
                Some((cluster_id, ClusterMean { mean, count }))
            })
            .collect())
    }
}

fn is_clusterable(embedding: &[f32]) -> bool {
    embedding.len() == CLUSTER_CENTROID_DIMENSIONS
        && embedding.iter().all(|value| value.is_finite())
}

fn cluster_summary(mean: &ClusterMean) -> ClusterSummary {
    let values: Vec<f64> = mean.mean.iter().copied().map(f64::from).collect();
    ClusterSummary {
        avg: encode_evector(&values),
        count: mean.count as i64,
    }
}

#[cfg(test)]
mod tests {
    use std::collections::{HashMap, HashSet};
    use std::fs;

    use super::{ClusteredBucket, FaceClusteringPlan, FaceClusteringRequest, FaceClusteringRun};
    use crate::ml_db::vector_encoding::{decode_evector, encode_evector};
    use crate::ml_db::{ClusterSummary, FaceRow};
    use crate::ml_store::tests::{index_path, meta, open};
    use crate::ml_store::{CLUSTER_CENTROID_DIMENSIONS, Error, Index, MlStore};

    const THRESHOLD: f64 = 0.24;

    fn embedding(degrees: f64) -> Vec<f64> {
        let mut values = vec![0.0; CLUSTER_CENTROID_DIMENSIONS];
        let radians = degrees.to_radians();
        values[0] = radians.cos();
        values[1] = radians.sin();
        values
    }

    fn face(file_id: i64, degrees: f64) -> FaceRow {
        FaceRow {
            file_id,
            face_id: format!("{file_id}_0"),
            detection_json: "{}".to_string(),
            embedding: embedding(degrees),
            score: 0.9,
            blur: 300.0,
            is_sideways: false,
            image_height: 100,
            image_width: 100,
            ml_version: 1,
        }
    }

    fn seed(store: &MlStore, faces: &[(i64, f64)]) {
        let rows: Vec<FaceRow> = faces
            .iter()
            .map(|&(file_id, degrees)| face(file_id, degrees))
            .collect();
        store.db().bulk_insert_faces(&rows).unwrap();
    }

    fn assign(store: &MlStore, assignments: &[(i64, &str)]) {
        let assignments: HashMap<String, String> = assignments
            .iter()
            .map(|&(file_id, cluster_id)| (format!("{file_id}_0"), cluster_id.to_string()))
            .collect();
        store
            .db()
            .update_face_id_to_cluster_id(&assignments)
            .unwrap();
    }

    fn request(file_ids: impl IntoIterator<Item = i64>) -> FaceClusteringRequest {
        FaceClusteringRequest {
            file_creation_times: file_ids
                .into_iter()
                .map(|file_id| (file_id, file_id))
                .collect(),
            rejected_cluster_ids: HashMap::new(),
            distance_threshold: THRESHOLD,
        }
    }

    fn run_to_end(store: &MlStore, run: &mut FaceClusteringRun) -> Vec<ClusteredBucket> {
        let mut buckets = Vec::new();
        while let Some(bucket) = store.cluster_next_bucket(run).unwrap() {
            buckets.push(bucket);
        }
        buckets
    }

    fn groups(store: &MlStore) -> Vec<Vec<String>> {
        let mut groups: Vec<Vec<String>> = store
            .db()
            .get_all_cluster_id_to_face_ids()
            .unwrap()
            .into_values()
            .map(|mut faces| {
                faces.sort();
                faces
            })
            .collect();
        groups.sort();
        groups
    }

    fn face_ids(file_ids: impl IntoIterator<Item = i64>) -> Vec<String> {
        let mut face_ids: Vec<String> = file_ids
            .into_iter()
            .map(|file_id| format!("{file_id}_0"))
            .collect();
        face_ids.sort();
        face_ids
    }

    fn cluster_of(store: &MlStore, file_id: i64) -> Option<String> {
        store
            .db()
            .get_cluster_id_for_face_id(&format!("{file_id}_0"))
            .unwrap()
    }

    fn summary_of(store: &MlStore, cluster_id: &str) -> (Vec<f64>, i64) {
        let summary = store
            .db()
            .get_cluster_to_cluster_summary(&[cluster_id.to_string()])
            .unwrap()
            .remove(cluster_id)
            .unwrap();
        (decode_evector(&summary.avg).unwrap(), summary.count)
    }

    fn assert_direction(actual: &[f64], degrees: f64) {
        let expected = embedding(degrees);
        for (actual, expected) in actual.iter().zip(&expected) {
            assert!((actual - expected).abs() < 1e-5, "{actual} != {expected}");
        }
    }

    #[test]
    fn new_faces_are_clustered_and_written_with_summaries_and_centroids() {
        let (_directory, store) = open();
        store.fill_cluster_centroid_index(false).unwrap();
        seed(
            &store,
            &[(1, 0.0), (2, 2.0), (3, 0.0), (4, 90.0), (5, 92.0)],
        );

        let mut run = store.start_face_clustering(request(1..=5)).unwrap();
        assert_eq!(
            run.plan(),
            FaceClusteringPlan {
                faces: 5,
                unclustered_faces: 5,
                missing_files: 0,
                invalid_faces: 0,
            }
        );
        assert_eq!(
            run_to_end(&store, &mut run),
            [ClusteredBucket {
                clustered_faces: 5,
                processed_faces: 5,
            }]
        );

        assert_eq!(groups(&store), [face_ids([1, 2, 3]), face_ids([4, 5])]);
        let cluster_id = cluster_of(&store, 1).unwrap();
        let (mean, count) = summary_of(&store, &cluster_id);
        assert_eq!(count, 3);
        assert_direction(&mean, 2.0 / 3.0);
        for file_id in [1, 4] {
            let cluster_id = cluster_of(&store, file_id).unwrap();
            assert!(store.contains(Index::ClusterCentroid, &cluster_id).unwrap());
        }
    }

    #[test]
    fn new_faces_join_existing_clusters_and_fold_into_their_summaries() {
        let (_directory, store) = open();
        seed(&store, &[(1, 0.0), (2, 0.0), (3, 0.0)]);
        assign(&store, &[(1, "p")]);
        let previous = ClusterSummary {
            avg: encode_evector(&embedding(0.0)),
            count: 3,
        };
        store
            .db()
            .upsert_cluster_summary_rows(&HashMap::from([("p".to_string(), previous)]))
            .unwrap();
        let mut rejecting = request(1..=3);
        rejecting
            .rejected_cluster_ids
            .insert("2_0".to_string(), HashSet::from(["p".to_string()]));

        let mut run = store.start_face_clustering(rejecting).unwrap();
        assert_eq!(run.plan().unclustered_faces, 2);
        run_to_end(&store, &mut run);

        assert_eq!(cluster_of(&store, 3).as_deref(), Some("p"));
        assert_ne!(cluster_of(&store, 2).as_deref(), Some("p"));
        let (mean, count) = summary_of(&store, "p");
        assert_eq!(count, 4);
        assert_direction(&mean, 0.0);
    }

    #[test]
    fn faces_of_missing_files_are_pruned_unless_clustered_and_invalid_embeddings_are_skipped() {
        let (_directory, store) = open();
        seed(&store, &[(1, 0.0), (2, 0.0), (4, 0.0)]);
        let mut invalid = face(3, 0.0);
        invalid.embedding[5] = f64::NAN;
        let mut short = face(5, 0.0);
        short.embedding.truncate(3);
        store.db().bulk_insert_faces(&[invalid, short]).unwrap();
        assign(&store, &[(1, "p")]);

        let mut run = store.start_face_clustering(request([3, 4, 5])).unwrap();
        assert_eq!(
            run.plan(),
            FaceClusteringPlan {
                faces: 1,
                unclustered_faces: 1,
                missing_files: 2,
                invalid_faces: 2,
            }
        );
        run_to_end(&store, &mut run);

        assert!(
            store
                .db()
                .get_faces_for_given_file_id(2)
                .unwrap()
                .is_empty()
        );
        assert_eq!(cluster_of(&store, 1).as_deref(), Some("p"));
        assert_eq!(cluster_of(&store, 3), None);
        assert_eq!(cluster_of(&store, 5), None);
        assert!(cluster_of(&store, 4).is_some());
    }

    #[test]
    fn clustered_libraries_have_no_buckets() {
        let (_directory, store) = open();
        seed(&store, &[(1, 0.0)]);
        assign(&store, &[(1, "p")]);
        let mut run = store.start_face_clustering(request([1])).unwrap();
        assert_eq!(run.plan().unclustered_faces, 0);
        assert!(run_to_end(&store, &mut run).is_empty());

        let mut empty = store.start_face_clustering(request([])).unwrap();
        assert!(run_to_end(&store, &mut empty).is_empty());
    }

    #[test]
    fn overlapping_buckets_continue_from_faces_clustered_in_earlier_buckets() {
        let (_directory, store) = open();
        seed(
            &store,
            &(1..=7).map(|file_id| (file_id, 0.0)).collect::<Vec<_>>(),
        );
        let mut run = store.start_face_clustering(request(1..=7)).unwrap();
        run.bucket_size = 4;
        run.bucket_step = 3;

        let processed: Vec<usize> = run_to_end(&store, &mut run)
            .iter()
            .map(|bucket| bucket.processed_faces)
            .collect();
        assert_eq!(processed, [4, 7]);
        assert_eq!(groups(&store), [face_ids(1..=7)]);
        let (_, count) = summary_of(&store, &cluster_of(&store, 1).unwrap());
        assert_eq!(count, 7);
    }

    #[test]
    fn fully_clustered_buckets_are_skipped() {
        let (_directory, store) = open();
        seed(
            &store,
            &(1..=7).map(|file_id| (file_id, 0.0)).collect::<Vec<_>>(),
        );
        assign(&store, &[(7, "p"), (6, "p"), (5, "p"), (4, "p")]);
        let mut run = store.start_face_clustering(request(1..=7)).unwrap();
        run.bucket_size = 4;
        run.bucket_step = 3;

        let buckets = run_to_end(&store, &mut run);
        assert_eq!(
            buckets,
            [ClusteredBucket {
                clustered_faces: 3,
                processed_faces: 7,
            }]
        );
        assert_eq!(groups(&store), [face_ids(1..=7)]);
    }

    #[test]
    fn buckets_committed_despite_a_failed_centroid_write_are_kept() {
        let (directory, store) = open();
        fs::create_dir(index_path(&directory, Index::ClusterCentroid)).unwrap();
        store
            .db()
            .set_meta("cluster_centroid.fill", "filled")
            .unwrap();
        seed(
            &store,
            &(1..=7).map(|file_id| (file_id, 0.0)).collect::<Vec<_>>(),
        );
        let mut run = store.start_face_clustering(request(1..=7)).unwrap();
        run.bucket_size = 4;
        run.bucket_step = 3;

        assert!(matches!(
            store.cluster_next_bucket(&mut run),
            Err(Error::Index(_))
        ));
        assert_eq!(meta(&store, "cluster_centroid.fill"), None);
        run_to_end(&store, &mut run);
        assert_eq!(groups(&store), [face_ids(1..=7)]);
    }

    #[test]
    fn non_finite_thresholds_are_rejected() {
        let (_directory, store) = open();
        let mut invalid = request([]);
        invalid.distance_threshold = f64::NAN;
        assert!(matches!(
            store.start_face_clustering(invalid),
            Err(Error::InvalidArgument(_))
        ));
    }
}
