import Foundation

// D04/T04: the worker returns compact frame-id ranges for long sources. The DTO must
// expand them without ever treating an omitted list as "zero frames processed".

let truncatedJSON = """
{
  "source_revision_id": "rev-1",
  "runtime_profile_id": "P-VISION-DEV-v1",
  "input_fingerprint": "abc",
  "total_declared_source_frames": 86400,
  "valid_decoded_frame_ids": [],
  "corrupted_decode_frame_ids": [],
  "unique_post_processor_frame_ids": [],
  "total_submitted_frames_with_overlap": 86400,
  "frame_input_coverage": 1.0,
  "detailed_pass_status": "completed",
  "semantic_understanding_certified": false,
  "vlm_frame_coverage": 1.0,
  "frame_ids_truncated": true,
  "frame_id_ranges": {
    "unique_post_processor": [[0, 3], [5, 5]],
    "valid_decoded": [[0, 5]]
  }
}
"""

let legacyJSON = """
{
  "source_revision_id": "rev-2",
  "runtime_profile_id": "P-VISION-DEV-v1",
  "input_fingerprint": "def",
  "total_declared_source_frames": 4,
  "valid_decoded_frame_ids": [0, 1, 2, 3],
  "corrupted_decode_frame_ids": [],
  "unique_post_processor_frame_ids": [0, 1, 2, 3],
  "total_submitted_frames_with_overlap": 4,
  "frame_input_coverage": 1.0,
  "detailed_pass_status": "completed",
  "semantic_understanding_certified": false
}
"""

@main
struct G2CoverageDTOTests {
    static func decode(_ json: String) throws -> G2AnalyzeCoverageDTO {
        try JSONDecoder().decode(G2AnalyzeCoverageDTO.self, from: Data(json.utf8))
    }

    static func main() throws {
        let truncated = try decode(truncatedJSON)
        precondition(truncated.frameIdsTruncated == true)
        precondition(truncated.resolvedUniquePostProcessorFrameIds == [0, 1, 2, 3, 5])
        precondition(truncated.resolvedValidDecodedFrameIds == [0, 1, 2, 3, 4, 5])

        let legacy = try decode(legacyJSON)
        precondition(legacy.frameIdsTruncated == nil)
        precondition(legacy.resolvedUniquePostProcessorFrameIds == [0, 1, 2, 3])
        precondition(legacy.resolvedValidDecodedFrameIds == [0, 1, 2, 3])

        print("G2 COVERAGE DTO RANGE TESTS PASSED")
    }
}
