use crate::domain::{Plan, Risk};
use serde_json::{Value, json};

pub struct Form {
    pub message: String,
    pub schema: Value,
}

fn reference_name(plan: &Plan) -> &str {
    plan.destination
        .strip_prefix("refs/heads/")
        .or_else(|| plan.destination.strip_prefix("refs/tags/"))
        .unwrap_or(&plan.destination)
}

fn action(plan: &Plan) -> String {
    let name = reference_name(plan);
    let target = if plan.destination.starts_with("refs/heads/") {
        "ветку"
    } else {
        "метку"
    };
    if plan.delete {
        format!("Удалить {target} «{name}»")
    } else if plan.old.is_empty() {
        format!("Создать {target} «{name}»")
    } else if plan.risks.contains(&Risk::ForceUpdate) {
        format!("Принудительно обновить {target} «{name}»")
    } else {
        format!("Обновить {target} «{name}»")
    }
}

fn context(plan: &Plan) -> String {
    let location = if plan.url.starts_with('/') || plan.url.starts_with("file:///") {
        "на этом компьютере"
    } else {
        &plan.url
    };
    let reason = plan
        .reason
        .as_ref()
        .map_or_else(String::new, |reason| format!("\nЦель запроса: {reason}"));
    format!("Репозиторий: {}\nНазначение: {location}{reason}", plan.name)
}

fn risk_heading(plan: &Plan, risk: Risk) -> &'static str {
    match risk {
        Risk::ProtectedBranch => "Основная ветка",
        Risk::ForceUpdate if plan.destination.starts_with("refs/tags/") => "Замена версии метки",
        Risk::ForceUpdate => "Принудительная отправка",
        Risk::DeleteBranch => "Удаление обычной ветки",
        Risk::DeleteProtectedBranch => "Удаление защищённой ветки",
        Risk::DeleteTag => "Удаление метки",
    }
}

pub fn risk_form(plan: &Plan, risk: Risk, index: usize, titled_choices: bool) -> Form {
    let name = reference_name(plan);
    let heading = risk_heading(plan, risk);
    let (consequence, permission) = match risk {
        Risk::ProtectedBranch => (
            format!("Изменение основной ветки «{name}» может затронуть работу других участников."),
            "Разрешить изменение основной ветки",
        ),
        Risk::ForceUpdate if plan.old.is_empty() => (
            format!(
                "Запрошена принудительная отправка. Ветки или метки «{name}» в назначении пока нет. Если она появится до отправки, операция остановится без её изменения."
            ),
            "Разрешить принудительную отправку",
        ),
        Risk::ForceUpdate if plan.destination.starts_with("refs/tags/") => (
            format!("Разрешается заменить версию кода, на которую указывает метка «{name}»."),
            "Разрешить замену версии метки",
        ),
        Risk::ForceUpdate => (
            format!(
                "Разрешается перезаписать историю ветки «{name}». Коммиты, которые есть только в назначении, могут исчезнуть из истории этой ветки."
            ),
            "Разрешить перезапись истории",
        ),
        Risk::DeleteBranch | Risk::DeleteProtectedBranch => (
            format!(
                "В назначении исчезнет ветка «{name}». Локальные копии ветки у участников сохранятся."
            ),
            if risk == Risk::DeleteProtectedBranch {
                "Разрешить удаление защищённой ветки"
            } else {
                "Удалить ветку"
            },
        ),
        Risk::DeleteTag => (
            format!(
                "В назначении исчезнет метка «{name}» — имя, указывающее на версию кода. Копии метки у участников сохранятся."
            ),
            "Разрешить удаление метки",
        ),
    };
    let single_click = plan.single_click_delete();
    let total = plan.risks.len() + usize::from(!single_click);
    let next = if single_click {
        "Кнопка «Удалить ветку» выполнит операцию. При отмене появится команда для ручного запуска."
    } else if index + 1 == plan.risks.len() {
        "На этом шаге ничего не меняется. Далее: последний шаг с вводом имени репозитория."
    } else {
        "На этом шаге ничего не меняется. Далее: отдельное подтверждение следующего риска."
    };
    let title = if single_click {
        "Удалить ветку?"
    } else {
        "Можно продолжить?"
    };
    let mut decision = json!({"type":"string","title":title});
    if titled_choices {
        decision["oneOf"] = json!([
            {"const":"stop","title":"Отменить всю операцию"},
            {"const":"continue","title":permission}
        ]);
    } else {
        // Older clients cannot label choices separately from their wire values.
        decision["enum"] = json!(["stop", "continue"]);
        decision["description"] = json!(format!(
            "stop — отменить всю операцию. continue — {permission}."
        ));
    }
    let address = if single_click {
        local_address(plan)
    } else {
        String::new()
    };
    Form {
        message: format!(
            "Шаг {} из {total}: {heading}\n\n{}\n{}{address}\n\n{consequence}\n\n{next}",
            index + 1,
            action(plan),
            context(plan),
        ),
        schema: json!({"type":"object","properties":{"decision":decision},"required":["decision"]}),
    }
}

fn local_address(plan: &Plan) -> String {
    if plan.url.starts_with('/') || plan.url.starts_with("file:///") {
        format!("\nАдрес назначения: {}", plan.url)
    } else {
        String::new()
    }
}

pub fn execution_form(plan: &Plan) -> Form {
    let total = plan.risks.len() + 1;
    let version = if plan.delete {
        String::new()
    } else {
        format!("\nВерсия кода: {} ({})", plan.source, &plan.new[..12])
    };
    let address = local_address(plan);
    Form {
        message: format!(
            "Шаг {total} из {total}: выполнить операцию\n\n{}\n{}{version}{address}\n\nПосле отправки этой формы операция выполнится один раз. При отказе изменений не будет; появится команда для ручного запуска.",
            action(plan),
            context(plan),
        ),
        schema: json!({"type":"object","properties":{"repository_name":{"type":"string","title":format!("Для выполнения введите: {}",plan.name),"description":"Введите имя репозитория точно, без пробелов в начале и конце.","minLength":1}},"required":["repository_name"]}),
    }
}
