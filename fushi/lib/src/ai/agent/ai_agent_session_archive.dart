import 'package:fushi_engine/ai/agent/agent_session_archive.dart';

export 'package:fushi_engine/ai/agent/agent_session_archive.dart'
    show
        AgentLiveSessions,
        DatabaseAgentSessionHistory,
        aiAgentSessionTitleOf,
        kAiAgentRemoteScene,
        saveAiAgentSessionArchive;

/// app 进程里正打开着的 AI 助手会话（本机 AI 页 `AiAgentController` + 互联 host 替
/// 已配对设备跑的远端会话共用这一份）：同一场会话只许一处打开（BUG-4067——host 本机
/// 能续接手机发起的会话，手机也能续接它；两份内存里的会话各自整场重存会互相冲掉）。
final AgentLiveSessions appAgentLiveSessions = AgentLiveSessions();
