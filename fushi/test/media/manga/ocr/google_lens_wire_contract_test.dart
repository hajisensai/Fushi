import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_protocol.dart';

/// BUG-1163：`google_lens_fixture.dart` 曾是「测试自己写的 protobuf 编码器 +
/// 自己抄一遍字段号」的闭环——字段号整体猜错，那批测试照样全绿而线上全错。
///
/// 这份测试是打破闭环的一环：下面的真值表**不是**从本仓实现抄的，而是从与本
/// 仓无血缘关系的第三方 protoc 产物逐条读出来的。实现里的
/// [GoogleLensWireFields] 只要有一个数写错（或将来被人「顺手改」），这里就红。
///
/// ## 真值来源（2026-07-27 实际抓取，非凭记忆）
///
/// `dimdenGD/chrome-lens-ocr` 的 `src/utils/proto_generated/*.cjs`，由
/// protoc-gen-js 从 Chromium `third_party/lens_server_proto/*.proto` 生成。
/// 该项目是独立 JS 实现，与本仓声明的血统（`1Selxo/Mangatan` →
/// `W1ght/Niratan` → Hibiki，见 `fushi/docs/licenses/google_lens_ocr.md`）无
/// 派生关系，可作独立证伪源。raw URL 前缀：
/// `https://raw.githubusercontent.com/dimdenGD/chrome-lens-ocr/main/src/utils/proto_generated/`
///
/// 抓到的原文片段（文件 → 取值器 → 字段号）：
///
/// - `lens_overlay_server_pb.cjs`：`LensOverlayServerRequest.getObjectsRequest`
///   → `getWrapperField(this, …LensOverlayObjectsRequest, 1)`；
///   `LensOverlayServerResponse.getObjectsResponse` → `…, 2`
/// - `lens_overlay_service_deps_pb.cjs`：`LensOverlayObjectsRequest`
///   `.getRequestContext` → `1`、`.getImageData` → `3`（2 号 reserved）；
///   `LensOverlayRequestContext.getRequestId` → `3`（1/2 号 reserved）、
///   `.getClientContext` → `4`；`LensOverlayObjectsResponse.getText` → `3`
/// - `lens_overlay_request_id_pb.cjs`：`getUuid` → `1`、`getSequenceId` → `2`、
///   `getImageSequenceId` → `3`
/// - `lens_overlay_client_context_pb.cjs`：`getPlatform` → `1`、`getSurface`
///   → `2`、`getLocaleContext` → `4`；`LocaleContext` 的
///   `getLanguage/getRegion/getTimeZone` → `1/2/3`
/// - `lens_overlay_image_data_pb.cjs`：`ImageData.getPayload` → `1`、
///   `.getImageMetadata` → `3`（2 号 reserved）；`ImagePayload.getImageBytes`
///   → `1`；`ImageMetadata.getWidth/getHeight` → `1/2`
/// - `lens_overlay_text_pb.cjs`：`Text.getTextLayout` → `1`；
///   `TextLayout.getParagraphsList` → `1`；`Paragraph.getLinesList` → `2`、
///   `Paragraph.getGeometry` → `3`；`Line.getWordsList` → `1`、
///   `Line.getGeometry` → `2`；`Word.getPlainText` → `2`、
///   `Word.getTextSeparator` → `3`
/// - `lens_overlay_geometry_pb.cjs`：`Geometry.getBoundingBox` → `1`；
///   `CenterRotatedBox` 的 `getCenterX/getCenterY/getWidth/getHeight/`
///   `getRotationZ` → `1/2/3/4/5`
///
/// 交叉印证（同样无血缘）：`AuroraWright/owocr` 的 `owocr/ocr.py`（`class
/// glens`）走同一 endpoint，字段名路径与上表一致。
///
/// ## 已知仍未覆盖
///
/// `CenterRotatedBox.coordinate_type`（6 号）本仓不读，无条件按归一化坐标处理。
/// 那属实现缺陷而非字段号问题，不在本测试范围内。真实响应里的可选字段与
/// presence 语义同样未覆盖——要覆盖必须入库一份脱敏真实响应字节，本仓没有。
void main() {
  group('Google Lens wire field numbers match an independent source', () {
    // 改这张表之前先回上面的 raw URL 复核；不允许为了让测试变绿而抄实现。
    const Map<String, int> externallySourced = <String, int>{
      // 请求侧
      'LensOverlayServerRequest.objects_request': 1,
      'LensOverlayObjectsRequest.request_context': 1,
      'LensOverlayObjectsRequest.image_data': 3,
      'LensOverlayRequestContext.request_id': 3,
      'LensOverlayRequestContext.client_context': 4,
      'LensOverlayRequestId.uuid': 1,
      'LensOverlayRequestId.sequence_id': 2,
      'LensOverlayRequestId.image_sequence_id': 3,
      'LensOverlayClientContext.platform': 1,
      'LensOverlayClientContext.surface': 2,
      'LensOverlayClientContext.locale_context': 4,
      'LocaleContext.language': 1,
      'LocaleContext.region': 2,
      'LocaleContext.time_zone': 3,
      'ImageData.payload': 1,
      'ImageData.image_metadata': 3,
      'ImagePayload.image_bytes': 1,
      'ImageMetadata.width': 1,
      'ImageMetadata.height': 2,
      // 响应侧
      'LensOverlayServerResponse.objects_response': 2,
      'LensOverlayObjectsResponse.text': 3,
      'Text.text_layout': 1,
      'TextLayout.paragraphs': 1,
      'TextLayout.Paragraph.lines': 2,
      'TextLayout.Paragraph.geometry': 3,
      'TextLayout.Line.words': 1,
      'TextLayout.Line.geometry': 2,
      'TextLayout.Word.plain_text': 2,
      'TextLayout.Word.text_separator': 3,
      'Geometry.bounding_box': 1,
      'CenterRotatedBox.center_x': 1,
      'CenterRotatedBox.center_y': 2,
      'CenterRotatedBox.width': 3,
      'CenterRotatedBox.height': 4,
      'CenterRotatedBox.rotation_z': 5,
    };

    const Map<String, int> implementation = <String, int>{
      'LensOverlayServerRequest.objects_request':
          GoogleLensWireFields.serverRequestObjectsRequest,
      'LensOverlayObjectsRequest.request_context':
          GoogleLensWireFields.objectsRequestRequestContext,
      'LensOverlayObjectsRequest.image_data':
          GoogleLensWireFields.objectsRequestImageData,
      'LensOverlayRequestContext.request_id':
          GoogleLensWireFields.requestContextRequestId,
      'LensOverlayRequestContext.client_context':
          GoogleLensWireFields.requestContextClientContext,
      'LensOverlayRequestId.uuid': GoogleLensWireFields.requestIdUuid,
      'LensOverlayRequestId.sequence_id':
          GoogleLensWireFields.requestIdSequenceId,
      'LensOverlayRequestId.image_sequence_id':
          GoogleLensWireFields.requestIdImageSequenceId,
      'LensOverlayClientContext.platform':
          GoogleLensWireFields.clientContextPlatform,
      'LensOverlayClientContext.surface':
          GoogleLensWireFields.clientContextSurface,
      'LensOverlayClientContext.locale_context':
          GoogleLensWireFields.clientContextLocaleContext,
      'LocaleContext.language': GoogleLensWireFields.localeContextLanguage,
      'LocaleContext.region': GoogleLensWireFields.localeContextRegion,
      'LocaleContext.time_zone': GoogleLensWireFields.localeContextTimeZone,
      'ImageData.payload': GoogleLensWireFields.imageDataPayload,
      'ImageData.image_metadata': GoogleLensWireFields.imageDataImageMetadata,
      'ImagePayload.image_bytes': GoogleLensWireFields.imagePayloadImageBytes,
      'ImageMetadata.width': GoogleLensWireFields.imageMetadataWidth,
      'ImageMetadata.height': GoogleLensWireFields.imageMetadataHeight,
      'LensOverlayServerResponse.objects_response':
          GoogleLensWireFields.serverResponseObjectsResponse,
      'LensOverlayObjectsResponse.text':
          GoogleLensWireFields.objectsResponseText,
      'Text.text_layout': GoogleLensWireFields.textTextLayout,
      'TextLayout.paragraphs': GoogleLensWireFields.textLayoutParagraphs,
      'TextLayout.Paragraph.lines': GoogleLensWireFields.paragraphLines,
      'TextLayout.Paragraph.geometry': GoogleLensWireFields.paragraphGeometry,
      'TextLayout.Line.words': GoogleLensWireFields.lineWords,
      'TextLayout.Line.geometry': GoogleLensWireFields.lineGeometry,
      'TextLayout.Word.plain_text': GoogleLensWireFields.wordPlainText,
      'TextLayout.Word.text_separator': GoogleLensWireFields.wordTextSeparator,
      'Geometry.bounding_box': GoogleLensWireFields.geometryBoundingBox,
      'CenterRotatedBox.center_x': GoogleLensWireFields.boxCenterX,
      'CenterRotatedBox.center_y': GoogleLensWireFields.boxCenterY,
      'CenterRotatedBox.width': GoogleLensWireFields.boxWidth,
      'CenterRotatedBox.height': GoogleLensWireFields.boxHeight,
      'CenterRotatedBox.rotation_z': GoogleLensWireFields.boxRotationZ,
    };

    test('every constant equals the externally sourced field number', () {
      expect(implementation, externallySourced);
    });

    test('the encoded request really carries those tags on the wire', () {
      // 不看常量、直接拆字节：即使有人把常量和真值表一起改错，这里也会在
      // 「实际写出的 tag」层面暴露出来。
      final Uint8List request = GoogleLensProtocol.makeRequest(
        imageData: Uint8List.fromList(<int>[1, 2, 3, 4]),
        width: 640,
        height: 480,
        language: 'ja',
        requestId: 7,
      );

      final Map<int, Uint8List> root = readLengthDelimitedFields(request);
      expect(
        root.keys.toList(),
        <int>[externallySourced['LensOverlayServerRequest.objects_request']!],
        reason: 'root must contain exactly objects_request',
      );

      final Map<int, Uint8List> objects = readLengthDelimitedFields(
        root[externallySourced['LensOverlayServerRequest.objects_request']!]!,
      );
      expect(
        objects.keys.toSet(),
        <int>{
          externallySourced['LensOverlayObjectsRequest.request_context']!,
          externallySourced['LensOverlayObjectsRequest.image_data']!,
        },
      );

      final Map<int, Uint8List> imageData = readLengthDelimitedFields(
        objects[externallySourced['LensOverlayObjectsRequest.image_data']!]!,
      );
      final Map<int, Uint8List> payload = readLengthDelimitedFields(
        imageData[externallySourced['ImageData.payload']!]!,
      );
      expect(
        payload[externallySourced['ImagePayload.image_bytes']!],
        <int>[1, 2, 3, 4],
        reason: 'image bytes must land on ImagePayload.image_bytes',
      );
    });
  });
}

/// 极简 protobuf 拆包：只收集 length-delimited（wire type 2）字段，其余跳过。
Map<int, Uint8List> readLengthDelimitedFields(Uint8List data) {
  final Map<int, Uint8List> result = <int, Uint8List>{};
  int offset = 0;

  int readVarint() {
    int value = 0;
    int shift = 0;
    while (offset < data.length) {
      final int byte = data[offset++];
      value |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return value;
      shift += 7;
    }
    throw StateError('truncated varint');
  }

  while (offset < data.length) {
    final int tag = readVarint();
    final int field = tag >> 3;
    switch (tag & 7) {
      case 0:
        readVarint();
      case 1:
        offset += 8;
      case 2:
        final int length = readVarint();
        result[field] = Uint8List.sublistView(data, offset, offset + length);
        offset += length;
      case 5:
        offset += 4;
      default:
        throw StateError('unsupported wire type ${tag & 7}');
    }
  }
  return result;
}
