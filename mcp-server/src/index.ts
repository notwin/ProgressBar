import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import * as fs from "fs";
import * as path from "path";
import * as crypto from "crypto";

// ── Data types (mirrors Swift Models.swift) ──

interface LogEntry {
  id: string;
  date: string;
  text: string;
}

interface TaskItem {
  id: string;
  title: string;
  status: "pending" | "in_progress" | "blocked" | "done";
  deadline: string;
  logs: LogEntry[];
  completedAt?: string;
}

interface TaskSection {
  id: string;
  name: string;
  tasks: TaskItem[];
  archived: TaskItem[];
}

interface AppData {
  version: number;
  sections: TaskSection[];
  themeId: string;
  activeSectionId: string;
}

// ── Data file paths (same as Swift PersistenceManager) ──

const HOME = process.env.HOME || "";
const ICLOUD_DIR = path.join(
  HOME,
  "Library/Mobile Documents/com~apple~CloudDocs/ProgressBar"
);
const LOCAL_DIR = path.join(HOME, "Library/Application Support/ProgressBar");
const DATA_FILE = fs.existsSync(ICLOUD_DIR)
  ? path.join(ICLOUD_DIR, "data.json")
  : path.join(LOCAL_DIR, "data.json");
const LOCAL_BACKUP = path.join(LOCAL_DIR, "data.json");

function loadData(): AppData {
  const raw = fs.readFileSync(DATA_FILE, "utf-8");
  return JSON.parse(raw) as AppData;
}

function saveData(data: AppData): void {
  const json = JSON.stringify(data, null, 2);
  fs.writeFileSync(DATA_FILE, json, "utf-8");
  // Also write local backup if using iCloud
  if (DATA_FILE !== LOCAL_BACKUP) {
    fs.mkdirSync(path.dirname(LOCAL_BACKUP), { recursive: true });
    fs.writeFileSync(LOCAL_BACKUP, json, "utf-8");
  }
}

function uuid(): string {
  return crypto.randomUUID();
}

function todayStr(): string {
  const d = new Date();
  return `${String(d.getFullYear()).slice(2)}.${String(d.getMonth() + 1).padStart(2, "0")}.${String(d.getDate()).padStart(2, "0")}`;
}

function fullDateStr(d: Date): string {
  return `${d.getFullYear()}.${String(d.getMonth() + 1).padStart(2, "0")}.${String(d.getDate()).padStart(2, "0")}`;
}

const STATUS_LABELS: Record<string, string> = {
  pending: "待开始",
  in_progress: "进行中",
  blocked: "已阻塞",
  done: "已完成",
};

// ── MCP Server ──

const server = new McpServer({
  name: "progressbar",
  version: "4.2.0",
});

// Tool: list_sections
server.tool("list_sections", "列出所有分区及其任务统计", {}, async () => {
  const data = loadData();
  const lines = data.sections.map((s) => {
    const total = s.tasks.length;
    const done = s.tasks.filter((t) => t.status === "done").length;
    const active = s.tasks.filter(
      (t) => t.status === "in_progress" || t.status === "blocked"
    ).length;
    const mark = s.id === data.activeSectionId ? " *" : "";
    return `${s.name}${mark}  (${done}/${total} 完成, ${active} 进行中, ${s.archived.length} 归档)  [id: ${s.id}]`;
  });
  return { content: [{ type: "text", text: lines.join("\n") || "暂无分区" }] };
});

// Tool: list_tasks
server.tool(
  "list_tasks",
  "列出指定分区的所有任务（默认当前活动分区）",
  {
    section: z
      .string()
      .optional()
      .describe("分区名称或 ID，留空则使用当前活动分区"),
    show_archived: z
      .boolean()
      .optional()
      .describe("是否显示归档任务，默认 false"),
  },
  async ({ section, show_archived }) => {
    const data = loadData();
    const sec = section
      ? data.sections.find((s) => s.name === section || s.id === section)
      : data.sections.find((s) => s.id === data.activeSectionId);
    if (!sec) return { content: [{ type: "text", text: "未找到该分区" }] };

    const formatTask = (t: TaskItem, i: number) => {
      const dl = t.deadline ? ` → ${t.deadline}` : "";
      const logCount = t.logs.length ? ` (${t.logs.length} 条日志)` : "";
      return `${i + 1}. [${STATUS_LABELS[t.status]}] ${t.title}${dl}${logCount}  [id: ${t.id}]`;
    };

    let out = `📊 ${sec.name}\n\n`;
    if (sec.tasks.length === 0) {
      out += "暂无任务\n";
    } else {
      out += sec.tasks.map(formatTask).join("\n") + "\n";
    }

    if (show_archived && sec.archived.length > 0) {
      out += `\n── 归档 (${sec.archived.length}) ──\n`;
      out += sec.archived.map(formatTask).join("\n") + "\n";
    }

    return { content: [{ type: "text", text: out }] };
  }
);

// Tool: get_task
server.tool(
  "get_task",
  "获取任务详情（含跟进日志）",
  {
    task_id: z.string().describe("任务 ID"),
  },
  async ({ task_id }) => {
    const data = loadData();
    for (const sec of data.sections) {
      const task = [...sec.tasks, ...sec.archived].find(
        (t) => t.id === task_id
      );
      if (task) {
        let out = `标题: ${task.title}\n`;
        out += `状态: ${STATUS_LABELS[task.status]}\n`;
        out += `分区: ${sec.name}\n`;
        if (task.deadline) out += `截止: ${task.deadline}\n`;
        if (task.completedAt) out += `完成时间: ${task.completedAt}\n`;
        if (task.logs.length > 0) {
          out += `\n跟进记录 (${task.logs.length}):\n`;
          for (const l of task.logs) {
            out += `  ${l.date}  ${l.text}\n`;
          }
        }
        return { content: [{ type: "text", text: out }] };
      }
    }
    return { content: [{ type: "text", text: "未找到该任务" }] };
  }
);

// Tool: add_task
server.tool(
  "add_task",
  "在指定分区新建任务",
  {
    title: z.string().describe("任务标题"),
    section: z
      .string()
      .optional()
      .describe("分区名称或 ID，留空则使用当前活动分区"),
    deadline: z
      .string()
      .optional()
      .describe("截止日期，格式 YYYY.MM.DD，如 2025.06.30"),
    status: z
      .enum(["pending", "in_progress", "blocked", "done"])
      .optional()
      .describe("初始状态，默认 pending"),
  },
  async ({ title, section, deadline, status }) => {
    const data = loadData();
    const sec = section
      ? data.sections.find((s) => s.name === section || s.id === section)
      : data.sections.find((s) => s.id === data.activeSectionId);
    if (!sec) return { content: [{ type: "text", text: "未找到该分区" }] };

    const task: TaskItem = {
      id: uuid(),
      title,
      status: status || "pending",
      deadline: deadline || "",
      logs: [],
    };
    sec.tasks.push(task);
    saveData(data);
    return {
      content: [
        {
          type: "text",
          text: `已创建任务「${title}」于分区「${sec.name}」 [id: ${task.id}]`,
        },
      ],
    };
  }
);

// Tool: update_task
server.tool(
  "update_task",
  "更新任务的标题、状态或截止日期",
  {
    task_id: z.string().describe("任务 ID"),
    title: z.string().optional().describe("新标题"),
    status: z
      .enum(["pending", "in_progress", "blocked", "done"])
      .optional()
      .describe("新状态"),
    deadline: z
      .string()
      .optional()
      .describe("新截止日期，格式 YYYY.MM.DD，传空字符串清除"),
  },
  async ({ task_id, title, status, deadline }) => {
    const data = loadData();
    for (const sec of data.sections) {
      const task = sec.tasks.find((t) => t.id === task_id);
      if (task) {
        if (title !== undefined) task.title = title;
        if (status !== undefined) {
          task.status = status;
          if (status === "done") {
            task.completedAt = fullDateStr(new Date());
          }
        }
        if (deadline !== undefined) task.deadline = deadline;
        saveData(data);
        return {
          content: [
            {
              type: "text",
              text: `已更新任务「${task.title}」 [${STATUS_LABELS[task.status]}]`,
            },
          ],
        };
      }
    }
    return { content: [{ type: "text", text: "未找到该任务" }] };
  }
);

// Tool: add_log
server.tool(
  "add_log",
  "为任务添加一条跟进记录",
  {
    task_id: z.string().describe("任务 ID"),
    text: z.string().describe("跟进内容"),
    date: z
      .string()
      .optional()
      .describe("日期，格式 YY.MM.DD，留空使用今天"),
  },
  async ({ task_id, text, date }) => {
    const data = loadData();
    for (const sec of data.sections) {
      const task = [...sec.tasks].find((t) => t.id === task_id);
      if (task) {
        const log: LogEntry = {
          id: uuid(),
          date: date || todayStr(),
          text,
        };
        task.logs.push(log);
        // Sort by date
        task.logs.sort((a, b) => a.date.localeCompare(b.date));
        saveData(data);
        return {
          content: [
            {
              type: "text",
              text: `已为「${task.title}」添加跟进记录`,
            },
          ],
        };
      }
    }
    return { content: [{ type: "text", text: "未找到该任务" }] };
  }
);

// Tool: archive_task
server.tool(
  "archive_task",
  "归档一个任务（从任务列表移到归档区）",
  {
    task_id: z.string().describe("任务 ID"),
  },
  async ({ task_id }) => {
    const data = loadData();
    for (const sec of data.sections) {
      const idx = sec.tasks.findIndex((t) => t.id === task_id);
      if (idx !== -1) {
        const [task] = sec.tasks.splice(idx, 1);
        sec.archived.push(task);
        saveData(data);
        return {
          content: [
            { type: "text", text: `已归档任务「${task.title}」` },
          ],
        };
      }
    }
    return { content: [{ type: "text", text: "未找到该任务" }] };
  }
);

// Tool: add_section
server.tool(
  "add_section",
  "新建一个分区",
  {
    name: z.string().describe("分区名称"),
  },
  async ({ name }) => {
    const data = loadData();
    if (data.sections.some((s) => s.name === name)) {
      return { content: [{ type: "text", text: `分区「${name}」已存在` }] };
    }
    const sec: TaskSection = {
      id: uuid(),
      name,
      tasks: [],
      archived: [],
    };
    data.sections.push(sec);
    saveData(data);
    return {
      content: [
        { type: "text", text: `已创建分区「${name}」 [id: ${sec.id}]` },
      ],
    };
  }
);

// Tool: delete_task
server.tool(
  "delete_task",
  "永久删除一个任务",
  {
    task_id: z.string().describe("任务 ID"),
  },
  async ({ task_id }) => {
    const data = loadData();
    for (const sec of data.sections) {
      let idx = sec.tasks.findIndex((t) => t.id === task_id);
      if (idx !== -1) {
        const [task] = sec.tasks.splice(idx, 1);
        saveData(data);
        return {
          content: [
            { type: "text", text: `已删除任务「${task.title}」` },
          ],
        };
      }
      idx = sec.archived.findIndex((t) => t.id === task_id);
      if (idx !== -1) {
        const [task] = sec.archived.splice(idx, 1);
        saveData(data);
        return {
          content: [
            { type: "text", text: `已删除归档任务「${task.title}」` },
          ],
        };
      }
    }
    return { content: [{ type: "text", text: "未找到该任务" }] };
  }
);

// ── Start server ──

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);
