use super::*;
use serde_json::{Value, from_value, json};

#[test]
fn document_checks_keep_their_existing_decisions_and_line_numbers() {
    let cases: Vec<(String, Vec<Value>, Value)> =
        serde_json::from_str(include_str!("parity.json")).unwrap();
    for (name, args, expected) in cases {
        let files = || from_value::<Files>(args[0].clone()).unwrap();
        let actual = match name.as_str() {
            "link_problems" => json!(checks::links(&files())),
            "path_problems" => json!(checks::paths(&files())),
            "adr_problems" => json!(checks::adrs(&files())),
            "section_sign_problems" => json!(checks::sections(&files())),
            "status_problems" => json!(checks::status(&files())),
            "opening_problems" => json!(checks::openings(&files())),
            "problems" => json!(checks::troubleshooting(
                args[0].as_str().unwrap(),
                args[1].as_str().unwrap()
            )),
            "parse_doc_marker" => json!(measurements::parse_marker(args[0].as_str().unwrap())),
            "collect" => json!(measurements::collect(&files())),
            "render" => json!(
                measurements::render(from_value(args[0].clone()).unwrap())
                    .split("\n## ")
                    .skip(1)
                    .collect::<Vec<_>>()
            ),
            _ => panic!("unknown document check: {name}"),
        };
        assert_eq!(actual, expected, "{name} {args:?}");
    }
}

#[test]
fn length_limit_applies_to_living_documents_at_the_top_level() {
    let doc = |name: &str| format!("docs/{name}");
    let files = Files::from([
        (doc("a.md"), "line\n".repeat(501)),
        (doc("research/b.md"), "line\n".repeat(501)),
        (doc("c.md"), "line\n".repeat(500)),
    ]);
    assert_eq!(
        checks::lengths(&files),
        [format!(
            "{}: 501 lines; split it by subject (the limit is 500)",
            doc("a.md")
        )]
    );
}

#[test]
fn a_generated_index_may_grow_past_the_limit() {
    let files = Files::from([("docs/measurements.md".to_string(), "строка\n".repeat(501))]);
    assert!(checks::lengths(&files).is_empty());
}

#[test]
fn rust_comment_measurement_links_back_to_its_file() {
    let source = "native/helper.rs";
    let comment = "// Measured on macOS 26.6: an observed result.";
    let files = Files::from([(source.into(), comment.into())]);
    let (rows, errors) = measurements::collect(&files);
    assert!(errors.is_empty());
    assert_eq!(
        rows,
        [["macOS", "26.6", &comment[3..], "`native/helper.rs`"]]
    );
}
