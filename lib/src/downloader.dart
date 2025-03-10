import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:collection/collection.dart';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_download_manager/flutter_download_manager.dart';

class DownloadManager {
  final Map<String, DownloadTask> _cache = <String, DownloadTask>{};
  final Queue<DownloadRequest> _queue = Queue();
  var dio = Dio();
  static const partialExtension = ".partial";
  static const tempExtension = ".temp";

  int globalBandwidth = 0;
  // var tasks = StreamController<DownloadTask>();

  int maxConcurrentTasks = 2;
  int runningTasks = 0;

  static final DownloadManager _dm = new DownloadManager._internal();

  DownloadManager._internal();

  factory DownloadManager({int? maxConcurrentTasks}) {
    if (maxConcurrentTasks != null) {
      _dm.maxConcurrentTasks = maxConcurrentTasks;
    }
    return _dm;
  }


  void Function(int, int ,int) createCallback(url, int partialFileLength) {
    // int _speedCount = 0;
    // int _speed = 0;
    // var timer = Timer.periodic(const Duration(seconds: 1), (timer) {
    //   _speed = _speedCount;
    //   _speedCount = 0 ;
    // });
    // var lastReceived = 0;
    var res =  (int received, int total , int _downloadSpeed) {
      // _speedCount += (received - lastReceived);
      // lastReceived = received;

      getDownload(url)?.progress.value =
          (received + partialFileLength) / (total + partialFileLength);
      // print(_speed);
      getDownload(url)?.onReceived?.call(total + partialFileLength, received + partialFileLength,received,total , _downloadSpeed);

      // if (received >= total){
      //   timer.cancel();
      // }
      if (total == -1) {}
    };

    return res;
  }


  Future<void> download(String url, String savePath, cancelToken,
      {forceDownload = false , int bandwidth = 0}) async {
    try {
      var task = getDownload(url);

      if (task == null || task.status.value == DownloadStatus.canceled) {
        return;
      }
      setStatus(task, DownloadStatus.downloading);

      if (kDebugMode) {
        print(url);
      }
      var file = File(savePath.toString());
      var partialFilePath = savePath + partialExtension;
      var partialFile = File(partialFilePath);

      var fileExist = await file.exists();
      var partialFileExist = await partialFile.exists();

      if (fileExist) {
        if (kDebugMode) {
          print("File Exists");
        }
        setStatus(task, DownloadStatus.completed);
      } else if (partialFileExist) {
        if (kDebugMode) {
          print("Partial File Exists");
        }
        // //追加 temp
        // await tryCombineTempFile(url);

        var partialFileLength = await partialFile.length();

        var response = await dio.download(url, partialFilePath,isReGet: true, bandwidth: bandwidth,
            onReceiveProgress: createCallback(url, partialFileLength),
            options: Options(
              headers: {HttpHeaders.rangeHeader: 'bytes=$partialFileLength-'},
            ),
            cancelToken: cancelToken,
            deleteOnError: false );

        if (response.statusCode == HttpStatus.partialContent) {
          // var ioSink = partialFile.openWrite(mode: FileMode.writeOnlyAppend);
          // var _f = File(partialFilePath + tempExtension);
          // await ioSink.addStream(_f.openRead());
          // await _f.delete();
          // await ioSink.close();
          // await partialFile.rename(savePath);
          await partialFile.rename(savePath);
          setStatus(task, DownloadStatus.completed);
        }
      } else {
        var response = await dio.download(url, partialFilePath,bandwidth: bandwidth,
            onReceiveProgress: createCallback(url, 0),
            cancelToken: cancelToken,
            deleteOnError: false);

        if (response.statusCode == HttpStatus.ok) {
          await partialFile.rename(savePath);
          setStatus(task, DownloadStatus.completed);
        }
      }
    } catch (e) {
      var task = getDownload(url)!;
      // print(e.toString());
      var partialFilePath = savePath + partialExtension;
      var partialFile = File(partialFilePath);

      if (e is DioError){
        if (e.error == "user_paused"){
          setStatus(task, DownloadStatus.paused);
        }
        else if (e.error == "user_cancel"){
          if (partialFile.existsSync()){
            partialFile.deleteSync();
          }
          setStatus(task, DownloadStatus.canceled);

        }
      }
      if (task.status.value != DownloadStatus.canceled &&
          task.status.value != DownloadStatus.paused) {
        //不去删除
        // if (partialFile.existsSync()){
        //   partialFile.deleteSync();
        // }
        setStatus(task, DownloadStatus.failed);
        runningTasks--;

        if (_queue.isNotEmpty) {
          _startExecution();
        }

        if (task.status.value != DownloadStatus.canceled){
          removeDownload(url);
        }
        rethrow;
      }
    }

    runningTasks--;

    if (_queue.isNotEmpty) {
      _startExecution();
    }
  }

  void disposeNotifiers(DownloadTask task) {
    // task.status.dispose();
    // task.progress.dispose();
  }

  void setStatus(DownloadTask? task, DownloadStatus status) {
    if (task != null) {
      task.status.value = status;

      // tasks.add(task);
      if (status.isCompleted) {
        disposeNotifiers(task);
      }
    }
  }

  Future<DownloadTask?> addDownload(String url, String savedDir) async {
    if (url.isNotEmpty) {
      if (savedDir.isEmpty) {
        savedDir = ".";
      }

      var isDirectory = await Directory(savedDir).exists();
      var downloadFilename = isDirectory
          ? savedDir + Platform.pathSeparator + getFileNameFromUrl(url)
          : savedDir;

      return _addDownloadRequest(DownloadRequest(url, downloadFilename));
    }
  }

  Future<DownloadTask> _addDownloadRequest(
    DownloadRequest downloadRequest,
  ) async {
    if (_cache[downloadRequest.url] != null) {
      if (!_cache[downloadRequest.url]!.status.value.isCompleted &&
          _cache[downloadRequest.url]!.request == downloadRequest) {
        // Do nothing
        return _cache[downloadRequest.url]!;
      } else {
        _queue.remove(_cache[downloadRequest.url]);
      }
    }

    _queue.add(DownloadRequest(downloadRequest.url, downloadRequest.path));
    var task = DownloadTask(_queue.last);

    _cache[downloadRequest.url] = task;

    // _startExecution();

    return task;
  }

  void startDownload(){
    _startExecution();
  }

  Future<void> pauseDownload(String url) async {
    if (kDebugMode) {
      print("Pause Download");
    }
    var task = getDownload(url)!;
    if (DownloadStatus.downloading != task.status.value){
      return ;
    }
    // setStatus(task, DownloadStatus.paused);
    task.request.cancelToken.cancel("user_paused");
    _queue.remove(task.request);

    // await tryCombineTempFile(url);
  }

  Future<void> cancelDownload(String url) async {
    if (kDebugMode) {
      print("Cancel Download");
    }
    var task = getDownload(url)!;
    // setStatus(task, DownloadStatus.canceled);
    if (DownloadStatus.downloading == task.status.value){
      _queue.remove(task.request);
      task.request.cancelToken.cancel("user_cancel");
    }

    // _cache.remove(url);
  }

  Future<void> resumeDownload(String url) async {
    if (kDebugMode) {
      print("Resume Download");
    }
    var task = getDownload(url)!;
    if (DownloadStatus.paused != task.status.value &&
        DownloadStatus.queued != task.status.value){
      return ;
    }
    // setStatus(task, DownloadStatus.downloading);
    task.request.cancelToken = CancelToken();
    _queue.add(task.request);

    _startExecution();
  }

  Future<void> removeDownload(String url) async {
    // cancelDownload(url);
    _cache.remove(url);
  }

  // Do not immediately call getDownload After addDownload, rather use the returned DownloadTask from addDownload
  DownloadTask? getDownload(String url) {
    return _cache[url];
  }

  Future<DownloadStatus> whenDownloadComplete(String url,
      {Duration timeout = const Duration(hours: 2)}) async {
    DownloadTask? task = getDownload(url);

    if (task != null) {
      return task.whenDownloadComplete(timeout: timeout);
    } else {
      return Future.error("Not found");
    }
  }

  List<DownloadTask> getAllDownloads() {
    return _cache.values.toList();
  }

  // Batch Download Mechanism
  Future<void> addBatchDownloads(List<String> urls, String savedDir) async {
    urls.forEach((url) {
      addDownload(url, savedDir);
    });
  }

  List<DownloadTask?> getBatchDownloads(List<String> urls) {
    return urls.map((e) => _cache[e]).toList();
  }

  Future<void> pauseBatchDownloads(List<String> urls) async {
    urls.forEach((element) {
      pauseDownload(element);
    });
  }

  Future<void> cancelBatchDownloads(List<String> urls) async {
    urls.forEach((element) {
      cancelDownload(element);
    });
  }

  Future<void> resumeBatchDownloads(List<String> urls) async {
    urls.forEach((element) {
      resumeDownload(element);
    });
  }

  ValueNotifier<double> getBatchDownloadProgress(List<String> urls) {
    ValueNotifier<double> progress = ValueNotifier(0);
    var total = urls.length;

    if (total == 0) {
      return progress;
    }

    if (total == 1) {
      return getDownload(urls.first)?.progress ?? progress;
    }

    var progressMap = Map<String, double>();

    urls.forEach((url) {
      DownloadTask? task = getDownload(url);

      if (task != null) {
        progressMap[url] = 0.0;

        if (task.status.value.isCompleted) {
          progressMap[url] = 1.0;
          progress.value = progressMap.values.sum / total;
        }

        var progressListener;
        progressListener = () {
          progressMap[url] = task.progress.value;
          progress.value = progressMap.values.sum / total;
        };

        task.progress.addListener(progressListener);

        var listener;
        listener = () {
          if (task.status.value.isCompleted) {
            progressMap[url] = 1.0;
            progress.value = progressMap.values.sum / total;
            task.status.removeListener(listener);
            task.progress.removeListener(progressListener);
          }
        };

        task.status.addListener(listener);
      } else {
        total--;
      }
    });

    return progress;
  }

  Future<List<DownloadTask?>?> whenBatchDownloadsComplete(List<String> urls,
      {Duration timeout = const Duration(hours: 2)}) async {
    var completer = Completer<List<DownloadTask?>?>();

    var completed = 0;
    var total = urls.length;

    urls.forEach((url) {
      DownloadTask? task = getDownload(url);

      if (task != null) {
        if (task.status.value.isCompleted) {
          completed++;

          if (completed == total) {
            completer.complete(getBatchDownloads(urls));
          }
        }

        var listener;
        listener = () {
          if (task.status.value.isCompleted) {
            completed++;

            if (completed == total) {
              completer.complete(getBatchDownloads(urls));
              task.status.removeListener(listener);
            }
          }
        };

        task.status.addListener(listener);
      } else {
        total--;

        if (total == 0) {
          completer.complete(null);
        }
      }
    });

    return completer.future.timeout(timeout);
  }

  void _startExecution() async {
    if (runningTasks == maxConcurrentTasks || _queue.isEmpty) {
      return;
    }

    while (_queue.isNotEmpty && runningTasks < maxConcurrentTasks) {
      runningTasks++;
      if (kDebugMode) {
        print('Concurrent workers: $runningTasks');
      }
      var currentRequest = _queue.removeFirst();

      download(
          currentRequest.url, currentRequest.path, currentRequest.cancelToken , bandwidth: globalBandwidth);

      await Future.delayed(Duration(milliseconds: 500), null);
    }
  }

  /// This function is used for get file name with extension from url
  String getFileNameFromUrl(String url) {
    return url.split('/').last;
  }
}
