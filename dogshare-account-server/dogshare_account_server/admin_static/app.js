"use strict";

const $ = (id) => document.getElementById(id);
const timeFormat = new Intl.DateTimeFormat("zh-CN", {
  year: "numeric", month: "2-digit", day: "2-digit",
  hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
});
const pageSize = 20;
const pages = {
  pair: { route: "pairs", queryKey: "q", input: $("pair-query"), query: "", offset: 0, total: 0 },
  event: { route: "events", queryKey: "pair_id", input: $("event-filter"), query: "", offset: 0, total: 0 },
};
const dialogs = {
  create: $("dialog-create"), manage: $("dialog-manage"), note: $("dialog-note"),
};
const batchFields = [
  "pair_id", "controller_username", "controller_password", "receiver_username", "receiver_password",
];
const sideNames = { a: "A 控制端", b: "B 被控端", both: "整组" };
const events = new Map([
  ["login", ["登录", "green"]], ["logout", ["主动退出", ""]],
  ["offline", ["掉线", "amber"]], ["expired", ["登录过期", "amber"]],
  ["reconnected", ["恢复在线", "green"]], ["device_replaced", ["换设备", "blue"]],
  ["kick", ["管理员踢下线", "amber"]], ["disable", ["管理员停用", "red"]],
  ["enable", ["管理员启用", "green"]], ["reset_password", ["管理员重置密码", "blue"]],
  ["create_pair", ["管理员生成配对", "blue"]],
  ["activate_pair", ["配对激活", "green"]], ["renew", ["管理员续期", "blue"]],
  ["update_note", ["管理员修改备注", "blue"]],
  ["admin_login", ["管理员登录", "blue"]], ["admin_logout", ["管理员退出", ""]],
]);
const actions = {
  kick: { label: "踢下线", hint: "撤销当前登录和远控授权。账号仍可使用原密码重新登录。" },
  disable: { label: "停用", hint: "撤销当前登录和远控授权，并阻止重新登录，直到再次启用。" },
  enable: { label: "启用", hint: "恢复此账号或配对的登录资格。若另一层仍停用，仍不能登录。" },
  reset_password: { label: "重置密码", hint: "旧密码和现有会话将失效。配对列表会显示新密码。" },
  renew: { label: "续期", hint: "续期后整组回到待激活。A 下次看到 B 的远控画面时重新开始 24 小时计时。原账号和密码继续使用，启停状态保持不变。" },
};
let session = null;
let sessionVersion = 0;
let visiblePage = "pair";
let selectedPair = null;
let selectedNotePair = null;
let batchDownload = null;

function make(tag, value, className) {
  const node = document.createElement(tag);
  if (value !== undefined) node.textContent = value;
  if (className) node.className = className;
  return node;
}

function setMessage(node, value) {
  node.textContent = value;
  node.hidden = !value;
}

function setBatchDownload(rows = null) {
  batchDownload = rows;
  $("download-credentials").hidden = !batchDownload;
}

function notice(value, kind = "success", batchRows = null) {
  const box = $("notice");
  box.dataset.kind = kind;
  box.hidden = !value;
  setMessage($("notice-text"), value);
  setBatchDownload(batchRows);
}

function date(value) {
  if (!Number.isFinite(value)) return "—";
  const moment = new Date(value * 1000);
  return Number.isNaN(moment.getTime()) ? "—" : timeFormat.format(moment);
}

function pill(value, tone = "") {
  return make("span", value, tone ? "pill " + tone : "pill");
}

function actionButton(value, onClick, appearance = "secondary") {
  const button = make("button", value, "button small " + appearance);
  button.type = "button";
  button.addEventListener("click", onClick);
  return button;
}

class RequestError extends Error {
  constructor(status, payload) {
    const generic = status === 0 ? "无法连接服务，请检查网络后重试。"
      : status === 429 ? "请求过于频繁，请稍后再试。"
      : "请求未能完成，请稍后重试。";
    super(typeof payload?.error === "string" && status !== 429 ? payload.error : generic);
    this.status = status;
    this.code = payload?.code;
  }
}

async function request(path, { method = "GET", body, anonymous = false, signal } = {}) {
  const version = sessionVersion;
  const headers = new Headers({ Accept: "application/json" });
  if (body !== undefined) headers.set("Content-Type", "application/json");
  if (method !== "GET" && !anonymous && session) {
    headers.set("X-CSRF-Token", session.csrf_token);
  }
  let response;
  try {
    response = await fetch("./api/" + path, {
      method, headers, body: body === undefined ? undefined : JSON.stringify(body),
      credentials: "same-origin", cache: "no-store", signal,
    });
  } catch (error) {
    if (signal?.aborted) throw error;
    throw new RequestError(0);
  }
  const payload = await response.json().catch(() => null);
  if (!response.ok) {
    if (response.status === 401 && !anonymous && version === sessionVersion && session) {
      showLogin("登录已失效，请重新登录。");
    }
    throw new RequestError(response.status, payload);
  }
  return payload;
}

function dismiss(dialog) {
  if (dialog.open) dialog.close();
}

function showLogin(message = "") {
  sessionVersion += 1;
  session = null;
  selectedPair = null;
  selectedNotePair = null;
  for (const [key, page] of Object.entries(pages)) {
    page.controller?.abort();
    $(key + "-content").replaceChildren();
  }
  for (const dialog of Object.values(dialogs)) dismiss(dialog);
  notice("");
  $("operator-name").textContent = "";
  $("admin-password").value = "";
  $("dashboard").hidden = true;
  $("session-loading").hidden = true;
  $("auth-screen").hidden = false;
  setMessage($("login-error"), message);
  $("admin-username").focus();
}

function showDashboard(payload) {
  if (typeof payload?.admin?.username !== "string" || typeof payload?.csrf_token !== "string") {
    showLogin("登录响应不完整，请重新登录。");
    return;
  }
  sessionVersion += 1;
  session = { admin: payload.admin, csrf_token: payload.csrf_token };
  for (const page of Object.values(pages)) {
    page.offset = 0;
    page.total = 0;
    page.query = "";
    page.input.value = "";
  }
  $("operator-name").textContent = session.admin.username;
  $("auth-screen").hidden = true;
  $("session-loading").hidden = true;
  $("dashboard").hidden = false;
  notice("");
  showPage("pair");
}

function showPage(key, pairId) {
  visiblePage = key;
  const pairActive = key === "pair";
  $("panel-pairs").hidden = !pairActive;
  $("panel-events").hidden = pairActive;
  $("tab-pairs").setAttribute("aria-current", pairActive ? "page" : "false");
  $("tab-events").setAttribute("aria-current", pairActive ? "false" : "page");
  if (pairId !== undefined) {
    pages.event.query = pairId;
    pages.event.input.value = pairId;
    pages.event.offset = 0;
  }
  $(key + "-heading").focus({ preventScroll: true });
  loadPage(key);
}

function table(columns, className, label) {
  const node = make("table", undefined, "table " + className);
  node.setAttribute("aria-label", label);
  const head = node.createTHead().insertRow();
  for (const column of columns) {
    const th = make("th", column);
    th.scope = "col";
    head.append(th);
  }
  return node;
}

function tableMessage(text) {
  return make("p", text, "table-message");
}

function endpointCell(endpoint, pairEnabled, side) {
  if (!endpoint) return make("span", "未配置", "muted");
  const box = make("div", undefined, "endpoint");
  const badges = make("div", undefined, "endpoint-badges");
  badges.append(
    pill(endpoint.enabled && pairEnabled ? "启用" : endpoint.enabled ? "随组停用" : "已停用",
      endpoint.enabled && pairEnabled ? "blue" : "red"),
    pill(endpoint.online ? "在线" : "离线", endpoint.online ? "green" : ""),
  );
  const password = typeof endpoint.password === "string" && endpoint.password ? endpoint.password : null;
  const passwordLine = make("div", undefined, "endpoint-password");
  passwordLine.append(make("span", "密码：", "muted"));
  if (password) {
    const copy = actionButton("复制", async () => {
      try {
        await navigator.clipboard.writeText(password);
        copy.textContent = "已复制";
      } catch {
        copy.textContent = "请手动复制";
      }
      setTimeout(() => { copy.textContent = "复制"; }, 1800);
    }, "ghost");
    copy.setAttribute("aria-label", "复制 " + sideNames[side] + "密码");
    passwordLine.append(make("code", password, "monospace"), copy);
  } else {
    passwordLine.append(make("span", "未留存", "muted"), make("span", "可在管理中重置", "muted"));
  }
  const accountLine = make("div", undefined, "endpoint-identity");
  const copyAccount = actionButton("复制", async () => {
    try {
      await navigator.clipboard.writeText(endpoint.username);
      copyAccount.textContent = "已复制";
    } catch {
      copyAccount.textContent = "请手动复制";
    }
    setTimeout(() => { copyAccount.textContent = "复制"; }, 1800);
  }, "ghost");
  copyAccount.setAttribute("aria-label", "复制 " + sideNames[side] + "账号");
  accountLine.append(make("span", endpoint.username, "endpoint-account monospace"), copyAccount);
  box.append(
    accountLine,
    passwordLine,
    badges,
    make("span", "设备：" + (endpoint.device_id ?? "未绑定"), "endpoint-info"),
    make("span", "最近活动：" + date(endpoint.last_seen), "endpoint-info"),
  );
  return box;
}

function pairExpiry(pair) {
  const state = pair.expiry_state ?? "unlimited";
  const labels = {
    unlimited: ["不限时", ""],
    pending: ["待激活", "amber"],
    active: ["生效中", "green"],
    expired: ["已过期", "red"],
  };
  const [label, tone] = Object.hasOwn(labels, state) ? labels[state] : ["未知", ""];
  const box = make("div", undefined, "pair-expiry");
  const status = make("div", undefined, "pair-expiry-status");
  status.append(make("span", "有效期：", "pair-expiry-label"), pill(label, tone));
  box.append(status);
  if (state === "pending") {
    box.append(make("span", "A 首次看到 B 的画面后计时 24 小时", "pair-expiry-info"));
  } else if (state === "active" || state === "expired") {
    const moment = date(pair.expires_at);
    box.append(make("span", (state === "active" ? "到期于 " : "过期于 ") + moment, "pair-expiry-info"));
  }
  return box;
}

function pairRows(items) {
  if (!items.length) return tableMessage(pages.pair.query ? "没有符合条件的配对。" : "还没有配对账号。");
  const node = table(["配对信息", "A 控制端", "B 被控端", "操作"], "pair-table", "配对账号");
  const body = node.createTBody();
  for (const pair of items) {
    const row = body.insertRow();
    const identity = row.insertCell();
    identity.className = "pair-identity";
    const note = typeof pair.note === "string" ? pair.note : "";
    const hasNote = Boolean(note.trim());
    const title = make("div", undefined, "pair-title-row");
    const label = make("p", hasNote ? note : "未添加备注", "pair-label" + (hasNote ? "" : " is-empty"));
    label.title = hasNote ? note : "未添加备注";
    const editNote = actionButton(hasNote ? "编辑" : "添加备注", () => openNote(pair), "ghost");
    editNote.setAttribute("aria-label", (hasNote ? "编辑" : "添加") + "配对 " + pair.pair_id + " 的备注");
    title.append(label, editNote);
    const reference = make("div", undefined, "pair-reference");
    const copyId = actionButton("复制", async () => {
      try {
        await navigator.clipboard.writeText(pair.pair_id);
        copyId.textContent = "已复制";
      } catch {
        copyId.textContent = "请手动复制";
      }
      setTimeout(() => { copyId.textContent = "复制"; }, 1800);
    }, "ghost");
    copyId.setAttribute("aria-label", "复制配对编号 " + pair.pair_id);
    reference.append(make("span", "编号", "reference-caption"), make("code", pair.pair_id, "monospace"), copyId);
    identity.append(
      title, reference,
      pill(pair.enabled ? "整组启用" : "整组停用", pair.enabled ? "blue" : "red"),
      pairExpiry(pair),
    );
    for (const side of ["a", "b"]) {
      const cell = row.insertCell();
      cell.dataset.label = sideNames[side];
      cell.append(endpointCell(pair[side], pair.enabled, side));
    }
    const controls = make("div", undefined, "pair-actions");
    controls.append(
      actionButton("管理", () => openManage(pair)),
      actionButton("记录", () => showPage("event", pair.pair_id), "ghost"),
    );
    row.insertCell().append(controls);
  }
  return node;
}

function eventRows(items) {
  if (!items.length) return tableMessage("没有符合条件的活动记录。");
  const node = table(["时间", "事件", "配对 / 端", "账号", "设备", "操作者", "详情"],
    "event-table", "操作记录");
  const body = node.createTBody();
  for (const item of items) {
    const row = body.insertRow();
    const [label, tone] = events.get(item.event) || [item.event || "事件", ""];
    row.insertCell().textContent = date(item.at);
    row.insertCell().append(pill(label, tone));
    const subject = row.insertCell();
    subject.textContent = [item.pair_id, sideNames[item.side]].filter(Boolean).join(" / ") || "—";
    subject.className = "monospace";
    let detail = item.detail;
    let formattedNote = false;
    if (item.event === "update_note" && typeof detail === "string") {
      try {
        const change = JSON.parse(detail);
        if (typeof change?.previous_note === "string" && typeof change.note === "string") {
          detail = "原备注：" + (change.previous_note.trim() ? change.previous_note : "（空）") +
            "\n新备注：" + (change.note.trim() ? change.note : "（空）");
          formattedNote = true;
        }
      } catch {}
    }
    for (const value of [item.username, item.device_id, item.actor, detail]) {
      row.insertCell().textContent = value ?? "—";
    }
    if (formattedNote) row.lastElementChild.style.whiteSpace = "pre-wrap";
  }
  return node;
}

async function loadPage(key, quiet = false) {
  if (!session) return;
  const page = pages[key];
  page.controller?.abort();
  const controller = new AbortController();
  page.controller = controller;
  const content = $(key + "-content");
  const previous = $(key + "-prev");
  const next = $(key + "-next");
  const meta = $(key + "-meta");
  content.setAttribute("aria-live", quiet ? "off" : "polite");
  if (!quiet) {
    previous.disabled = true;
    next.disabled = true;
    content.replaceChildren(tableMessage("正在加载…"));
    meta.textContent = "";
  }
  if (key === "event") $("event-clear").hidden = !page.query;
  const params = new URLSearchParams({ limit: String(pageSize), offset: String(page.offset) });
  if (page.query) params.set(page.queryKey, page.query);
  try {
    const result = await request(page.route + "?" + params, { signal: controller.signal });
    if (!session || controller.signal.aborted) return;
    if (!Array.isArray(result?.items) || !Number.isInteger(result?.total)) {
      throw new Error("服务返回的数据格式不正确，请刷新重试。");
    }
    page.total = result.total;
    if (!result.items.length && page.offset > 0) {
      page.offset = Math.max(0, page.offset - pageSize);
      return loadPage(key);
    }
    content.replaceChildren(key === "pair" ? pairRows(result.items) : eventRows(result.items));
    meta.textContent = page.total
      ? `第 ${page.offset + 1}–${page.offset + result.items.length} 条，共 ${page.total} 条`
      : "共 0 条";
    previous.disabled = page.offset === 0;
    next.disabled = page.offset + result.items.length >= page.total;
  } catch (error) {
    if (!quiet && !controller.signal.aborted && session) content.replaceChildren(tableMessage(error.message));
  } finally {
    if (page.controller === controller) page.controller = null;
  }
}

async function busy(form, submit, label, run) {
  if (form.getAttribute("aria-busy") === "true") return;
  const fields = Array.from(form.elements);
  const previous = fields.map((field) => field.disabled);
  const originalLabel = submit.textContent;
  form.setAttribute("aria-busy", "true");
  fields.forEach((field) => { field.disabled = true; });
  submit.textContent = label;
  try {
    await run();
  } finally {
    form.removeAttribute("aria-busy");
    fields.forEach((field, index) => { field.disabled = previous[index]; });
    submit.textContent = originalLabel;
  }
}

function batchRows(rows, count) {
  if (!Array.isArray(rows) || rows.length !== count ||
      rows.some((row) => batchFields.some((field) => typeof row?.[field] !== "string" || !row[field]))) {
    return null;
  }
  return rows.map((row) => batchFields.map((field) => row[field]));
}

function csvField(value) {
  const guarded = /^(?:[\t\r\n]|\s*[=+\-@])/.test(value) ? "'" + value : value;
  return '"' + guarded.replaceAll('"', '""') + '"';
}

$("download-credentials").addEventListener("click", () => {
  if (!batchDownload) return;
  const csv = [batchFields, ...batchDownload].map((row) => row.map(csvField).join(",")).join("\r\n");
  const url = URL.createObjectURL(new Blob(["\uFEFF", csv, "\r\n"], { type: "text/csv;charset=utf-8" }));
  const link = make("a");
  link.href = url;
  link.download = "dogshare-pairs.csv";
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
});

function canRenewPair(scope) {
  return scope === "both" && selectedPair?.expiryState === "expired";
}

function updateAction() {
  const scope = $("action-side").value;
  const kind = $("action-kind");
  const allowRenew = canRenewPair(scope);
  if ((kind.value === "reset_password" && scope === "both") || (kind.value === "renew" && !allowRenew)) {
    kind.value = "kick";
  }
  kind.querySelector('option[value="reset_password"]').disabled = scope === "both";
  const renewOption = kind.querySelector('option[value="renew"]');
  renewOption.hidden = renewOption.disabled = !allowRenew;
  const action = actions[kind.value];
  const submit = $("action-submit");
  submit.textContent = "确认" + action.label;
  submit.classList.toggle("danger", kind.value === "disable" || kind.value === "reset_password");
  submit.classList.toggle("primary", !submit.classList.contains("danger"));
  $("action-hint").textContent = action.hint +
    (scope === "both" && kind.value !== "renew" ? " 重置密码时请选择 A 或 B。" : "");
}

function openManage(pair) {
  selectedPair = { id: pair.pair_id, expiryState: pair.expiry_state };
  $("action-pair").textContent = pair.pair_id;
  $("action-created").textContent = date(pair.created_at);
  $("action-side").value = "both";
  $("action-kind").value = "kick";
  updateAction();
  setMessage($("action-error"), "");
  dialogs.manage.showModal();
}

function updateNoteCount() {
  $("note-count").textContent = $("note-text").value.length + " / 500";
}

function openNote(pair) {
  selectedNotePair = pair.pair_id;
  $("note-pair").textContent = pair.pair_id;
  $("note-text").value = typeof pair.note === "string" ? pair.note : "";
  updateNoteCount();
  setMessage($("note-error"), "");
  dialogs.note.showModal();
  $("note-text").focus();
}

$("auth-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const username = $("admin-username").value.trim();
  const password = $("admin-password").value;
  $("admin-password").value = "";
  setMessage($("login-error"), "");
  await busy(form, $("login-submit"), "登录中…", async () => {
    try {
      const payload = await request("session", { method: "POST", body: { username, password }, anonymous: true });
      showDashboard(payload);
    } catch (error) {
      setMessage($("login-error"), error.status === 401 ? "管理员账号或密码不正确。" : error.message);
    }
  });
});

$("logout").addEventListener("click", async (event) => {
  const button = event.currentTarget;
  button.disabled = true;
  try {
    await request("session", { method: "DELETE" });
    showLogin();
  } catch (error) {
    if (session) notice(error.message, "error");
  } finally {
    button.disabled = false;
  }
});

$("pair-create").addEventListener("click", () => {
  $("create-form").reset();
  setMessage($("create-error"), "");
  dialogs.create.showModal();
});

$("create-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const count = $("create-count").valueAsNumber;
  const version = sessionVersion;
  setMessage($("create-error"), "");
  await busy(event.currentTarget, $("create-submit"), "生成中…", async () => {
    try {
      const result = await request("pairs", { method: "POST", body: { count } });
      if (!session || version !== sessionVersion) return;
      dismiss(dialogs.create);
      notice("已生成 " + count + " 组配对，密码显示在配对列表中。",
        "success", batchRows(result?.credentials, count));
      pages.pair.offset = 0;
      pages.pair.query = "";
      pages.pair.input.value = "";
      loadPage("pair");
    } catch (error) {
      if (session && version === sessionVersion) setMessage($("create-error"), error.message);
    }
  });
});

$("action-side").addEventListener("change", updateAction);
$("action-kind").addEventListener("change", updateAction);
$("action-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const side = $("action-side").value;
  const action = $("action-kind").value;
  const pairId = selectedPair?.id;
  const version = sessionVersion;
  if (!pairId || !Object.hasOwn(actions, action) ||
      (action === "reset_password" && side === "both") ||
      (action === "renew" && !canRenewPair(side))) return;
  setMessage($("action-error"), "");
  await busy(event.currentTarget, $("action-submit"), "处理中…", async () => {
    try {
      await request("pairs/" + encodeURIComponent(pairId) + "/action", {
        method: "POST", body: { side, action },
      });
      if (!session || version !== sessionVersion) return;
      dismiss(dialogs.manage);
      const suffix = action === "reset_password" ? "配对列表将显示新密码。"
        : action === "renew" ? "配对已回到待激活。" : "";
      notice(sideNames[side] + "：" + actions[action].label + "完成。" + suffix);
      loadPage(visiblePage);
    } catch (error) {
      if (session && version === sessionVersion) setMessage($("action-error"), error.message);
    }
  });
});

$("note-text").addEventListener("input", updateNoteCount);
$("note-clear").addEventListener("click", () => {
  $("note-text").value = "";
  updateNoteCount();
  $("note-text").focus();
});
$("note-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const pairId = selectedNotePair;
  const version = sessionVersion;
  const note = $("note-text").value;
  if (!pairId) return;
  setMessage($("note-error"), "");
  if (note.length > 500) {
    setMessage($("note-error"), "备注最多 500 字，请缩短后再保存。");
    return;
  }
  await busy(event.currentTarget, $("note-submit"), "保存中…", async () => {
    try {
      const result = await request("pairs/" + encodeURIComponent(pairId) + "/note", {
        method: "PUT", body: { note },
      });
      if (!session || version !== sessionVersion) return;
      if (result?.ok !== true || result.pair_id !== pairId || typeof result.note !== "string") {
        throw new Error("保存响应不完整，请重试。");
      }
      dismiss(dialogs.note);
      selectedNotePair = null;
      notice(result.note.trim() ? "备注已保存。" : "备注已清空。");
      loadPage("pair");
    } catch (error) {
      if (session && version === sessionVersion) setMessage($("note-error"), error.message);
    }
  });
});

for (const [key, page] of Object.entries(pages)) {
  $(key + "-search").addEventListener("submit", (event) => {
    event.preventDefault();
    page.query = page.input.value.trim();
    page.offset = 0;
    loadPage(key);
  });
  $(key + "-refresh").addEventListener("click", () => loadPage(key));
  $(key + "-prev").addEventListener("click", () => {
    page.offset = Math.max(0, page.offset - pageSize);
    loadPage(key);
  });
  $(key + "-next").addEventListener("click", () => {
    if (page.offset + pageSize < page.total) {
      page.offset += pageSize;
      loadPage(key);
    }
  });
}

$("event-clear").addEventListener("click", () => {
  pages.event.query = "";
  pages.event.input.value = "";
  pages.event.offset = 0;
  loadPage("event");
});
$("tab-pairs").addEventListener("click", () => showPage("pair"));
$("tab-events").addEventListener("click", () => showPage("event"));

for (const dialog of Object.values(dialogs)) {
  dialog.querySelectorAll("[data-close]").forEach((button) => {
    button.addEventListener("click", () => dismiss(dialog));
  });
  dialog.addEventListener("cancel", (event) => {
    if (dialog.querySelector("[aria-busy='true']")) event.preventDefault();
  });
}
window.addEventListener("pagehide", () => {
  sessionVersion += 1;
  session = null;
  setBatchDownload();
  pages.pair.controller?.abort();
  $("pair-content").replaceChildren();
});

async function restoreSession() {
  try {
    showDashboard(await request("session", { anonymous: true }));
  } catch (error) {
    showLogin(error.status === 401 ? "" : error.message);
  }
}
window.addEventListener("pageshow", (event) => {
  if (event.persisted) restoreSession();
});
setInterval(() => {
  const content = $(visiblePage + "-content");
  if (session && document.visibilityState === "visible" && !pages[visiblePage].controller &&
      !content.contains(document.activeElement) && !Object.values(dialogs).some((dialog) => dialog.open)) {
    loadPage(visiblePage, true);
  }
}, 30000);
restoreSession();
