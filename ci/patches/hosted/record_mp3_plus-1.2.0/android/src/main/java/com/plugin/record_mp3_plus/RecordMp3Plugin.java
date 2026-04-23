package com.plugin.record_mp3_plus;

import com.plugin.record_mp3_plus.record.MP3Recorder;
import com.plugin.record_mp3_plus.record.RecordMsg;
import com.plugin.record_mp3_plus.record.RecordStatus;
import com.plugin.record_mp3_plus.record.port.RecordListener;

import java.io.File;

import io.flutter.Log;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/**
 * RecordMp3Plugin
 */
public class RecordMp3Plugin implements MethodCallHandler, FlutterPlugin {

    private MethodChannel methodChannel;
    private MP3Recorder recorder;
    private RecordListener listener;

    /**
     * Plugin registration.
     */
    @Override
    public void onMethodCall(MethodCall call, Result result) {
        switch (call.method) {
            case "start":
                String filePath = call.argument("path");
                onStartRecord(filePath);
                break;
            case "pause":
                onPauseRecord();
                break;
            case "resume":
                onResumeRecord();
                break;
            case "stop":
                onStopRecord();
                break;
        }
    }

    private void init(BinaryMessenger messenger) {
        methodChannel = new MethodChannel(messenger, "record_mp3_plus");
        methodChannel.setMethodCallHandler(this);

        this.listener = new RecordListener() {
            @Override
            public void onRecorderStatusChange(RecordStatus status) {
            }

            @Override
            public void onFileNotFound() {
                onErrorCallBack(RecordMsg.MSG_FILE_NOT_FOUNT, "FILE NOT FOUNT");
            }

            @Override
            public void onPermissionError() {
                onErrorCallBack(RecordMsg.MSG_PERMISSION_ERROR, "mic permission error");
            }

            @Override
            public void onComplete() {
                System.out.println("record complete");
            }

            @Override
            public void onIOExecption() {
                onErrorCallBack(RecordMsg.MSG_IO_EXCEPTION, "IO_EXCEPTION");
            }

            @Override
            public void onRecordMayUsed() {
                onErrorCallBack(RecordMsg.MSG_RECORD_HAS_USED, "RECORD_HAS_USED");
            }
        };
    }


    //开启录音
    private void onStartRecord(String path) {
        Log.d("RecordMp3Plugin", "record = " + path);
        File recordFile = new File(path);
        if (recorder != null) {
            recorder.breakRecord();
            recorder.setRecordFile(recordFile);
            recorder.start();
        } else {
            recorder = new MP3Recorder(recordFile, listener);
            recorder.start();
        }
    }

    //继续录音
    private void onResumeRecord() {
        if (recorder != null) {
            recorder.resume();
        }
    }

    //暂停录音
    private void onPauseRecord() {
        if (recorder != null) {
            recorder.pause();
        }
    }

    //停止录音,并输出录音文件
    private void onStopRecord() {
        if (recorder != null) {
            recorder.stop();
            recorder = null;
        }
    }

    private void onErrorCallBack(int tag, String msg) {
        Log.d("RecordMp3", "error = " + msg);
        methodChannel.invokeMethod("onRecordError", tag, new Result() {
            @Override
            public void success(Object o) {
            }

            @Override
            public void error(String s, String s1, Object o) {
            }

            @Override
            public void notImplemented() {
            }
        });
    }

    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        init(binding.getBinaryMessenger());
    }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        if (methodChannel != null) {
            methodChannel.setMethodCallHandler(null);
            methodChannel = null;
        }
        if (recorder != null) {
            recorder.breakRecord();
            recorder = null;
        }
    }
}
