// Public @oai/sky window API cases. Inputs use ${NAME} fixture placeholders.
// The safe default suite contains only list_apps; every app-targeted case must be
// explicitly enabled because the official client can display an authorization UI.
export const oracleCases = Object.freeze([
  { id: "list_apps", operation: "list_apps", input: null, risk: "read_only" },
  {
    id: "get_app_state.full",
    operation: "get_app_state",
    input: { app: "${APP}", disableDiff: true },
    risk: "target_authorization",
  },
  {
    id: "get_app_state.diff",
    operation: "get_app_state",
    input: { app: "${APP}" },
    risk: "target_authorization",
  },
  {
    id: "click.element",
    operation: "click",
    input: { app: "${APP}", element_index: "${ELEMENT_INDEX}" },
    risk: "mutating",
  },
  {
    id: "click.coordinate",
    operation: "click",
    input: { app: "${APP}", x: "${X}", y: "${Y}" },
    risk: "mutating",
  },
  {
    id: "drag.coordinate",
    operation: "drag",
    input: {
      app: "${APP}", from_x: "${FROM_X}", from_y: "${FROM_Y}",
      to_x: "${TO_X}", to_y: "${TO_Y}",
    },
    risk: "mutating",
  },
  {
    id: "paste.text",
    operation: "paste",
    input: { app: "${APP}", format: "text", text: "${TEXT}" },
    risk: "mutating",
  },
  {
    id: "perform_secondary_action.element",
    operation: "perform_secondary_action",
    input: {
      app: "${APP}", element_index: "${ELEMENT_INDEX}", action: "${ACTION}",
    },
    risk: "mutating",
  },
  {
    id: "press_key.chord",
    operation: "press_key",
    input: { app: "${APP}", key: "${KEY}" },
    risk: "mutating",
  },
  {
    id: "scroll.element",
    operation: "scroll",
    input: {
      app: "${APP}", element_index: "${ELEMENT_INDEX}",
      direction: "${DIRECTION}", pages: "${PAGES}",
    },
    risk: "mutating",
  },
  {
    id: "select_text.element",
    operation: "select_text",
    input: {
      app: "${APP}", element_index: "${ELEMENT_INDEX}", text: "${SELECT_TEXT}",
      selection_type: "text",
    },
    risk: "mutating",
  },
  {
    id: "set_value.element",
    operation: "set_value",
    input: { app: "${APP}", element_index: "${ELEMENT_INDEX}", value: "${TEXT}" },
    risk: "mutating",
  },
  {
    id: "type_text.focused",
    operation: "type_text",
    input: { app: "${APP}", text: "${TEXT}" },
    risk: "mutating",
  },
]);

