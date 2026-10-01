#!/usr/bin/env node
// Claude Code PreToolUse hook (Bash / PowerShell): refuses a bare local
// `flutter test|analyze|build` or `gradlew` that does not go through the
// machine-wide heavy-run lease (fushi/tool/heavy.dart), and tells the agent
// the wrapped form. Root CLAUDE.md "本机重活一律走租约" is the rule; this only
// gives it teeth. Enable in .claude/settings.json:
//
//   "hooks": { "PreToolUse": [ { "matcher": "Bash|PowerShell", "hooks": [
//     { "type": "command", "command": "node tool/claude_hooks/require_heavy_lease.mjs" } ] } ] }
//
// pre_push_check.dart / flutter_test_failures.dart take the lease themselves
// and are not matched; `FUSHI_HEAVY=off` in the command opts out explicitly.

const HEAVY_FLUTTER_VERBS = new Set(['test', 'analyze', 'build']);

/** Base name without directory, quotes or extension, lower-cased. */
function exeName(token) {
  const bare = token.replace(/^['"]|['"]$/g, '').replace(/\\/g, '/');
  const name = bare.split('/').pop().toLowerCase();
  return name.replace(/\.(bat|cmd|exe|ps1)$/, '');
}

/** The first command segment that is a bare heavy run, or null. */
export function findBareHeavyCommand(command) {
  if (typeof command !== 'string' || command.length === 0) return null;
  if (/heavy\.dart/.test(command) || /FUSHI_HEAVY\s*=\s*['"]?off/i.test(command)) {
    return null;
  }
  for (const raw of command.split(/&&|\|\||[;|\n]/)) {
    const tokens = raw
      .trim()
      .replace(/^&\s*/, '') // PowerShell call operator
      .split(/\s+/)
      .filter((t) => t.length > 0 && !/^\w+=/.test(t)); // VAR=x prefixes
    if (tokens.length === 0) continue;
    let exe = exeName(tokens[0]);
    let rest = tokens.slice(1);
    if (exe === 'fvm' && rest.length > 0) {
      exe = exeName(rest[0]);
      rest = rest.slice(1);
    }
    if (exe === 'gradlew' || exe === 'gradle') return raw.trim();
    if (exe !== 'flutter') continue;
    const verb = rest.find((t) => !t.startsWith('-'));
    if (verb && HEAVY_FLUTTER_VERBS.has(verb.toLowerCase())) return raw.trim();
  }
  return null;
}

export function denial(segment) {
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        `本机重活必须走租约（根 CLAUDE.md「本机重活一律走租约」）：\`${segment}\` ` +
        '请在 fushi/ 下改写成 `dart tool/heavy.dart -- <原命令>`（用 dart 直接跑，不加 run）。' +
        '它会排队等槽位与内存、低优先级运行、内存封顶，不会拖垮用户的电脑或与别的 agent 互抢 build/。' +
        '`dart tool/heavy.dart --status` 可看当前占用。',
    },
  };
}

async function main() {
  let input = '';
  for await (const chunk of process.stdin) input += chunk;
  let payload;
  try {
    payload = JSON.parse(input);
  } catch {
    return; // Not ours to judge.
  }
  const segment = findBareHeavyCommand(payload?.tool_input?.command);
  if (segment) process.stdout.write(JSON.stringify(denial(segment)));
}

if (process.argv[1]?.endsWith('require_heavy_lease.mjs')) {
  await main();
}
