import { describe, expect, it } from "vitest";
import {
  connectorToolAdvertised,
  filterToolsListFrame,
  parseConnectorAllowedToolsEnv,
  parseConnectorServiceSlugsEnv,
} from "./connector-advertisement.ts";
import type { ConnectorToolGrant } from "../shared/wire.ts";

const grants = (value: Record<string, ConnectorToolGrant>) => value;

// The harness half (serialization and its 32 KB caps) moved to
// jac/harness/connectors.jac with its tests; these cover what the bridge
// decodes and filters.
describe("connector advertisement allowlist env", () => {
  it("reads back a grants record the harness serialized", () => {
    const record = grants({ gmail: { tools: ["GMAIL_SEND_EMAIL", "GMAIL_GET_EMAIL"] }, slack: { tools: "*" } });
    expect(parseConnectorAllowedToolsEnv(JSON.stringify(record))).toEqual(record);
  });

  it("reads the service slug list, and an unreadable one as empty", () => {
    expect(parseConnectorServiceSlugsEnv(JSON.stringify(["bland_ai", "bland"]))).toEqual(["bland_ai", "bland"]);
    expect(parseConnectorServiceSlugsEnv(undefined)).toEqual([]);
    expect(parseConnectorServiceSlugsEnv("{not json")).toEqual([]);
    expect(parseConnectorServiceSlugsEnv(JSON.stringify(["bland_ai", "Bad Slug"]))).toEqual([]);
  });

  it("parses an empty record (no tools granted) but treats anything unreadable as absent", () => {
    expect(parseConnectorAllowedToolsEnv(JSON.stringify({}))).toEqual({});
    expect(parseConnectorAllowedToolsEnv(undefined)).toBeNull();
    expect(parseConnectorAllowedToolsEnv("")).toBeNull();
    expect(parseConnectorAllowedToolsEnv("{not json")).toBeNull();
    expect(parseConnectorAllowedToolsEnv("[]")).toBeNull();
    expect(parseConnectorAllowedToolsEnv(JSON.stringify({ "Bad Slug": { tools: "*" } }))).toBeNull();
    expect(parseConnectorAllowedToolsEnv(JSON.stringify({ gmail: { tools: [] } }))).toBeNull();
    expect(parseConnectorAllowedToolsEnv(JSON.stringify({ gmail: { tools: ["lowercase_name"] } }))).toBeNull();
    expect(parseConnectorAllowedToolsEnv(JSON.stringify({ gmail: { tools: "read" } }))).toBeNull();
  });
});

describe("connector tool advertisement", () => {
  it("keeps granted tools, their connection flow, and the meta-tools", () => {
    const partial = grants({ gmail: { tools: ["GMAIL_SEND_EMAIL"] } });
    expect(connectorToolAdvertised("GMAIL_SEND_EMAIL", partial)).toBe(true);
    expect(connectorToolAdvertised("GMAIL_MANAGE_CONNECTIONS", partial)).toBe(true);
    expect(connectorToolAdvertised("GMAIL_WAIT_FOR_CONNECTIONS", partial)).toBe(true);
    expect(connectorToolAdvertised("COMPOSIO_SEARCH_TOOLS", partial)).toBe(true);
    expect(connectorToolAdvertised("COMPOSIO_GET_TOOL_SCHEMAS", partial)).toBe(true);
    expect(connectorToolAdvertised("COMPOSIO_MULTI_EXECUTE_TOOL", partial)).toBe(true);
    // Session-level connection meta-tools prefix as service "composio",
    // which no grant names, so they ride the meta-tool list.
    expect(connectorToolAdvertised("COMPOSIO_MANAGE_CONNECTIONS", partial)).toBe(true);
    expect(connectorToolAdvertised("COMPOSIO_WAIT_FOR_CONNECTIONS", partial)).toBe(true);
    // not granted: another tool on the granted service, another service
    expect(connectorToolAdvertised("GMAIL_GET_EMAIL", partial)).toBe(false);
    expect(connectorToolAdvertised("SLACK_POST_MESSAGE", partial)).toBe(false);
    expect(connectorToolAdvertised("SLACK_MANAGE_CONNECTIONS", partial)).toBe(false);
  });

  it("widens to the whole service on a star grant", () => {
    const star = grants({ slack: { tools: "*" } });
    expect(connectorToolAdvertised("SLACK_POST_MESSAGE", star)).toBe(true);
    expect(connectorToolAdvertised("SLACK_LIST_CHANNELS", star)).toBe(true);
    expect(connectorToolAdvertised("NOTION_CREATE_PAGE", star)).toBe(false);
  });

  it("resolves underscored service slugs from the connected-service catalog before splitting", () => {
    const record = grants({ bland: { tools: "*" }, bland_ai: { tools: ["BLAND_AI_MAKE_CALL"] } });
    expect(connectorToolAdvertised("BLAND_AI_MAKE_CALL", record, ["bland", "bland_ai"])).toBe(true);
    // bland_ai claims BLAND_AI_* before bland's star grant can widen it.
    expect(connectorToolAdvertised("BLAND_AI_SEND_SMS", record, ["bland", "bland_ai"])).toBe(false);
    expect(connectorToolAdvertised("BLAND_SEND_SMS", record, ["bland", "bland_ai"])).toBe(true);
  });

  it("does not let a plain-prefix grant advertise an underscored connected service's tools", () => {
    expect(connectorToolAdvertised("BLAND_AI_MAKE_CALL", grants({ bland: { tools: "*" } }), ["bland_ai"])).toBe(false);
  });

  it("advertises nothing at all — not even the meta-tools — when no tools are granted", () => {
    const none = grants({});
    expect(connectorToolAdvertised("COMPOSIO_SEARCH_TOOLS", none)).toBe(false);
    expect(connectorToolAdvertised("COMPOSIO_MANAGE_CONNECTIONS", none)).toBe(false);
    expect(connectorToolAdvertised("COMPOSIO_WAIT_FOR_CONNECTIONS", none)).toBe(false);
    expect(connectorToolAdvertised("GMAIL_SEND_EMAIL", none)).toBe(false);
    expect(connectorToolAdvertised("GMAIL_MANAGE_CONNECTIONS", none)).toBe(false);
  });
});

describe("tools/list frame filtering", () => {
  const frame = {
    jsonrpc: "2.0" as const,
    id: 9,
    result: {
      tools: [
        { name: "COMPOSIO_SEARCH_TOOLS" },
        { name: "COMPOSIO_GET_TOOL_SCHEMAS" },
        { name: "COMPOSIO_MULTI_EXECUTE_TOOL" },
        { name: "COMPOSIO_MANAGE_CONNECTIONS" },
        { name: "COMPOSIO_WAIT_FOR_CONNECTIONS" },
        { name: "GMAIL_SEND_EMAIL", description: "send" },
        { name: "GMAIL_GET_EMAIL", description: "read" },
        { name: "GMAIL_MANAGE_CONNECTIONS" },
        { name: "SLACK_POST_MESSAGE" },
        { name: "NOTION_WAIT_FOR_CONNECTIONS" },
      ],
    },
  };

  it("trims the list to the grants and keeps the granted tool's own fields", () => {
    const filtered = filterToolsListFrame(structuredClone(frame), grants({ gmail: { tools: ["GMAIL_SEND_EMAIL"] } }));
    expect((filtered.result as { tools: Array<{ name: string }> }).tools.map((tool) => tool.name)).toEqual([
      "COMPOSIO_SEARCH_TOOLS",
      "COMPOSIO_GET_TOOL_SCHEMAS",
      "COMPOSIO_MULTI_EXECUTE_TOOL",
      "COMPOSIO_MANAGE_CONNECTIONS",
      "COMPOSIO_WAIT_FOR_CONNECTIONS",
      "GMAIL_SEND_EMAIL",
      "GMAIL_MANAGE_CONNECTIONS",
    ]);
    expect(JSON.stringify(filtered)).toContain('"description":"send"');
  });

  it("filters to an empty list for a bot with no granted tools", () => {
    const filtered = filterToolsListFrame(structuredClone(frame), grants({}));
    expect((filtered.result as { tools: unknown[] }).tools).toEqual([]);
  });

  it("passes frames it cannot read through unchanged instead of guessing", () => {
    const noResult = { jsonrpc: "2.0" as const, id: 10, error: { code: -32000, message: "upstream" } };
    expect(filterToolsListFrame(noResult, grants({ gmail: { tools: "*" } }))).toBe(noResult);
    const noTools = { jsonrpc: "2.0" as const, id: 11, result: {} };
    expect(filterToolsListFrame(noTools, grants({ gmail: { tools: "*" } }))).toBe(noTools);
    const nameless = { jsonrpc: "2.0" as const, id: 12, result: { tools: [{ description: "unnamed" }] } };
    expect(filterToolsListFrame(nameless, grants({ gmail: { tools: "*" } }))).toEqual(nameless);
  });
});
