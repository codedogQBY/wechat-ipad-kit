const fs = require("node:fs");
const path = require("node:path");

function readApiPrefix() {
  if (process.env.IPAD_API_PREFIX) {
    return process.env.IPAD_API_PREFIX;
  }

  try {
    return fs.readFileSync(path.resolve(__dirname, "../.state/prefix.txt"), "utf8").trim() || "/api";
  } catch {
    return "/api";
  }
}

class IpadClient {
  constructor({ baseUrl, prefix, wxid }) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.prefix = prefix.replace(/^\/*|\/*$/g, "");
    this.wxid = wxid;
  }

  async post(endpoint, body = {}, query = {}) {
    const url = new URL(`${this.baseUrl}/${this.prefix}${endpoint}`);
    for (const [key, value] of Object.entries(query)) {
      url.searchParams.set(key, value);
    }

    const response = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(30000),
    });
    const text = await response.text();
    let result;
    try {
      result = JSON.parse(text);
    } catch {
      throw new Error(`${endpoint} returned invalid JSON (HTTP ${response.status})`);
    }

    if (!response.ok || (typeof result.Code === "number" && result.Code < 0)) {
      const error = new Error(`${endpoint} failed: HTTP ${response.status}, Code ${result.Code}, ${result.Message || ""}`);
      error.code = result.Code;
      throw error;
    }
    return result;
  }

  async getSelf() {
    const result = await this.post("/Login/GetCacheInfo", {}, { wxid: this.wxid });
    if (result.Code !== 1 || !result.Data) {
      throw new Error(`登录缓存不可用: Code ${result.Code}, ${result.Message || ""}`);
    }
    return result.Data;
  }

  async syncMessages() {
    const result = await this.post("/Msg/Sync", {
      Wxid: this.wxid,
      Scene: 0,
      Synckey: "",
    });
    if (result.Code !== 0) {
      throw new Error(`消息同步失败: Code ${result.Code}, ${result.Message || ""}`);
    }
    return result.Data?.AddMsgs || result.Data?.addMsgs || [];
  }

  async sendText(toWxid, content) {
    const result = await this.post("/Msg/SendTxt", {
      Wxid: this.wxid,
      ToWxid: toWxid,
      Content: content,
      Type: 1,
      At: "",
    });
    if (result.Code !== 0) {
      throw new Error(`发送消息失败: Code ${result.Code}, ${result.Message || ""}`);
    }
    return result;
  }
}

module.exports = { IpadClient, readApiPrefix };
