const { registerDouCommand, DouCommandHandler, getDouCommand } = require("./wechat/command/dou");
const { IpadClient, readApiPrefix } = require("./ipadClient");

const wxid = process.env.WECHAT_WXID;
if (!wxid) {
  console.error("请设置 WECHAT_WXID（从 bash scripts/05-verify.sh 的 Wxid 输出复制）");
  process.exit(1);
}

const client = new IpadClient({
  baseUrl: process.env.IPAD_API_URL || "http://127.0.0.1:8058",
  prefix: readApiPrefix(),
  wxid,
});
const gameMap = new Map();
const contacts = new Map();
let botName = process.env.WECHAT_BOT_NAME || "";
let polling = false;
let pollTimer;

function stringValue(value) {
  if (typeof value === "string") return value;
  return value?.String_ || value?.string || "";
}

function contactFor(id) {
  if (!contacts.has(id)) {
    contacts.set(id, {
      id,
      name: () => id,
      say: (text) => client.sendText(id, text),
    });
  }
  return contacts.get(id);
}

const bot = {
  Contact: {
    find: async ({ name }) => contacts.get(name) || null,
  },
};

function normalizeGroupContent(raw, senderId) {
  const prefix = new RegExp(`^${senderId.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}:\\s*\\n`);
  return raw.replace(prefix, "");
}

function buildMessage(addMsg) {
  const from = stringValue(addMsg.FromUserName || addMsg.fromUserName);
  const to = stringValue(addMsg.ToUserName || addMsg.toUserName);
  const raw = stringValue(addMsg.Content || addMsg.content);
  const roomId = from.endsWith("@chatroom") ? from : "";
  let senderId = roomId ? raw.match(/^([^:\n]+):\s*\n/)?.[1] : from;

  if (!senderId || senderId === wxid || to !== wxid) return null;
  const content = roomId ? normalizeGroupContent(raw, senderId) : raw;
  const contact = contactFor(senderId);
  const room = roomId
    ? {
        id: roomId,
        say: (text) => client.sendText(roomId, text),
      }
    : null;
  const mentioned = Boolean(
    roomId &&
      (content.includes(`@${botName}`) ||
        content.includes(`@${wxid}`) ||
        (!botName && /@[^\s\u2005]+/.test(content))),
  );
  const commandText = mentioned
    ? content.replace(botName ? `@${botName}` : /@[^\s\u2005]+/, "").replace(/^\s*[\u2005\s]+/, "")
    : content;

  return {
    roomId,
    content: commandText.trim(),
    contact,
    room,
    message: {
      room: () => room,
      talker: () => contact,
      mentionSelf: async () => mentioned,
      mentionText: async () => commandText,
      say: (text) => (room ? room.say(text) : client.sendText(senderId, text)),
    },
  };
}

async function handleMessage(addMsg) {
  const type = addMsg.MsgType ?? addMsg.msgType;
  if (Number(type) !== 1) return;

  const event = buildMessage(addMsg);
  if (!event) return;

  // 私聊只作为发牌渠道；游戏命令在群聊中执行。
  if (!event.room) return;

  const commandText = event.content;
  if (
    !(await event.message.mentionSelf()) &&
    !/^cc/i.test(commandText) &&
    commandText !== "摸鱼"
  ) {
    return;
  }

  const commandName = getDouCommand(await event.message.mentionSelf(), commandText);
  try {
    await DouCommandHandler.handle(commandName, {
      gameMap,
      room: event.room,
      contact: event.contact,
      message: event.message,
      bot,
    });
  } catch (error) {
    console.error(`处理群消息失败 (${event.roomId}):`, error);
    await event.message.say("处理命令时出错，请稍后重试。").catch(() => {});
  }
}

async function poll() {
  if (polling) return;
  polling = true;
  try {
    const messages = await client.syncMessages();
    for (const message of messages) {
      await handleMessage(message);
    }
  } catch (error) {
    console.error(`同步失败: ${error.message}`);
    if (error.code === -13) {
      clearInterval(pollTimer);
      console.error("iPad 协议会话已超时。请重新扫码登录并确认登录，再启动机器人。");
      process.exitCode = 1;
    }
  } finally {
    polling = false;
  }
}

async function main() {
  const self = await client.getSelf();
  botName ||= self.NickName || self.Nickname || "";
  registerDouCommand();
  console.log(`斗地主机器人已连接: ${botName || wxid} (${wxid})`);
  console.log(`API: ${client.baseUrl}/${client.prefix}`);
  pollTimer = setInterval(poll, Math.max(500, Number(process.env.BOT_POLL_INTERVAL_MS) || 1500));
  await poll();
}

main().catch((error) => {
  console.error(`启动失败: ${error.message}`);
  process.exitCode = 1;
});
