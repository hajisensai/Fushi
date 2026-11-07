# 自定义 HTTP TTS 接口 / Custom HTTP TTS

在朗读声音设置里添加声音，选「自定义 HTTP 接口」。用来接 Fushi 没有专门适配的自建 TTS 服务（GPT-SoVITS 各下游分支、各类 WebUI 自带的 API 等）。Fushi 不预置任何第三方服务地址，地址和模板都由你填。

Add a read-aloud voice and pick **Custom HTTP API**. For self-hosted TTS servers Fushi has no dedicated adapter for. Fushi ships no third-party endpoint; you fill everything in.

## 参数 / Parameters

| 参数 | 说明 |
|---|---|
| 地址 Endpoint | 完整接口地址，例如 `http://127.0.0.1:8001/infer_single`。可以带固定 query。 |
| 请求方法 Method | `POST` / `GET`。`GET` 不能带请求体。 |
| Query 模板 | 追加到地址后的 query，例如 `text={text}&text_lang={lang}`。代入值自动 URL 编码，不用手动转义。 |
| JSON 请求体模板 | 必须是合法 JSON。占位符写在**字符串**里：`"text": "{text}"`。文本里的引号、换行、反斜杠由编码器自动转义。整个值恰好是 `"{speed}"` 时按数字发送。没写 `Content-Type` 请求头时自动用 `application/json`。 |
| 请求头 Headers | 每行一个 `名称: 值`。 |
| API key | 凭据，按凭据保存（不同步、不进备份 / Profile 分享）。在请求头、Query、请求体里写 `{api_key}` 引用。 |
| 语言值 Language | 代入 `{lang}`，按服务端要求的写法填（`ja`、`日语`……）。 |
| 速度 Speed | 代入 `{speed}`，留空为 `1.0`。朗读倍速仍由本地播放器控制，一般保持 1.0。 |
| 返回格式 Response | 直接返回音频（WAV / MP3）；JSON 里的 base64 音频（可带 `data:audio/...;base64,` 前缀）；JSON 里的音频地址（相对地址按接口地址解析，再 GET 一次）。 |
| 返回字段路径 | JSON 返回时的字段路径，点分隔，列表用下标：`audio_url`、`data.0.audio`。 |

占位符 / Placeholders: `{text}` `{lang}` `{speed}` `{api_key}`。未知的 `{…}` 原样保留。

**凭据规则**：请求头 / Query / 请求体里名字像凭据的字段（`Authorization`、`Cookie`、`*token*`、`*secret*`、`*password*`、`api_key`、`app_key`、`access_key`……）必须写 `{api_key}`，写明文校验不过、也不会发出。音频地址与接口不同源（scheme / 主机 / 端口不同）时，取音频不带任何你配的请求头。失败提示与日志只有错误码和 HTTP 状态码，不含地址、模板或响应正文。

返回的音频按内容判断格式，只认 WAV / MP3；其它（HTML 错误页、OGG 等）按「响应无效」处理。

## 示例：AI-Hobbyist/GPT-SoVITS-Inference（`gsvi.py`）

该分支的推理 API（`gsvi.py`，默认 `-s 0.0.0.0 -p 8001`，`-k` 设推理密钥）有 `POST /infer_single`（按情感推理），返回 `{"msg": ..., "audio_url": ...}`。以下字段名取自该仓库 `gsvi.py` 的 `inferWithEmotions`；模型名、情感、版本按你本机已装的模型改（`GET /models/{version}` 可列出）。

- 地址：`http://127.0.0.1:8001/infer_single`
- 请求方法：`POST`
- 语言值：`日语`（该接口的 `text_lang` / `prompt_text_lang` 收中文名称：`中文` `英语` `日语` `粤语` `韩语` `中英混合` `日英混合` `多语种混合`……）
- API key：启动时 `-k` 设的密钥（没设就留空）
- 返回格式：JSON 里的音频地址；返回字段路径：`audio_url`
- JSON 请求体模板：

```json
{
  "app_key": "{api_key}",
  "dl_url": "http://127.0.0.1:8001",
  "version": "v4",
  "model_name": "你的模型名",
  "prompt_text_lang": "日语",
  "emotion": "默认",
  "text": "{text}",
  "text_lang": "{lang}",
  "text_split_method": "不切",
  "media_type": "wav",
  "speed_facter": "{speed}"
}
```

- `dl_url` 必填成客户端能访问到的地址：不填时服务端用自己的监听地址拼 `audio_url`，默认是 `http://0.0.0.0:8001/...`，在 Windows 上连不上。服务在另一台机器上就填那台机器的地址。
- `text_split_method` 用 `不切`：Fushi 已经按句切好，再切会多出停顿。
- 密钥错误时该接口仍返回 200、`audio_url` 为空，Fushi 显示「响应无效」。

该分支还提供 OpenAI 风格的 `POST /v1/audio/speech`，也可以直接用「OpenAI 兼容语音接口」引擎（地址填 `http://127.0.0.1:8001`）；但那条路由的语言、情感等只能取服务端默认值，要指定语言 / 情感时用上面的自定义 HTTP 配置。

## 示例：GET + query、直接返回音频

参数都在 query 里、直接回音频字节的服务：

- 地址：服务的合成接口地址；请求方法 `GET`
- Query 模板：按该服务的参数名写，例如 `text={text}&lang={lang}`
- 返回格式：直接返回音频
