use crate::confirmation::{self, Form};
use crate::domain::Arguments;
use crate::git::Git;
use crate::process::{self, Cancellation};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

pub fn execute(
    args: &Arguments,
    cancel: &Cancellation,
    titled_choices: bool,
    confirm: impl Fn(Form, Instant) -> Result<Value, String>,
) -> Result<Value, String> {
    let deadline = Instant::now() + Duration::from_secs(300);
    let git = Git::new(cancel.clone(), deadline)?;
    let plan = git.prepare(args)?;
    let confirmed = || -> Result<(), String> {
        cancel.check(deadline)?;
        for (index, risk) in plan.risks.iter().enumerate() {
            let form = confirmation::risk_form(&plan, *risk, index, titled_choices);
            let answer = confirm(form, deadline)?;
            if answer.get("action") != Some(&json!("accept"))
                || answer.get("content") != Some(&json!({"decision":"continue"}))
            {
                return Err(format!("Confirmation stopped at risk {}.", index + 1));
            }
        }
        if !plan.single_click_delete() {
            let form = confirmation::execution_form(&plan);
            let answer = confirm(form, deadline)?;
            if answer.get("action") != Some(&json!("accept"))
                || answer.get("content") != Some(&json!({"repository_name":plan.name}))
            {
                return Err(
                    "The final confirmation was declined or the name did not match.".into(),
                );
            }
        }
        if !git.unchanged(&plan)? {
            return Err(
                "The repository, source, destination or branch protection changed during confirmation.".into(),
            );
        }
        cancel.check(deadline)
    };
    if let Err(reason) = confirmed() {
        return Ok(plan.stopped(&reason));
    }
    // There is one execution site. Consent is consumed even when spawning fails.
    match process::run(
        &mut git.command(&plan.command[1..]),
        cancel,
        Instant::now() + Duration::from_secs(600),
        deadline,
    ) {
        Ok(output) if output.status.success() => Ok(
            json!({"status":"completed","message":"The confirmed push finished.","output":output.stdout.chars().rev().take(16000).collect::<String>().chars().rev().collect::<String>()}),
        ),
        Ok(_) => Ok(
            json!({"status":"failed","message":"Git rejected or could not finish the push. This confirmation is consumed. Check the remote before requesting another push."}),
        ),
        Err(process::RunError::NotStarted(reason)) => Ok(plan.stopped(&reason)),
        Err(process::RunError::SpawnFailed(reason)) => {
            Ok(plan.stopped(&format!("{reason}; this confirmation is consumed.")))
        }
        Err(process::RunError::Interrupted(_)) => Ok(
            json!({"status":"outcome_unknown","message":"Git was interrupted or could not finish after confirmation. Check the remote before retrying."}),
        ),
    }
}
