import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart';
import 'package:dio/dio.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/app_dio.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';
import 'package:pica_comic/network/eh_network/get_gallery_id.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_models.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/foundation/image_loader/image_recombine.dart';
import '../base.dart';
import '../network/eh_network/eh_main_network.dart';
import '../network/hitomi_network/image.dart';
import '../network/res.dart';

class ImageManager {
  static ImageManager? cache;

  ///用于标记正在加载的项目, 避免出现多个异步函数加载同一张图片
  static Map<String, DownloadProgress> loadingItems = {};

  /// Image cache manager for reader and download manager
  factory ImageManager() => cache ??= ImageManager._create();

  static bool get haveTask => loadingItems.isNotEmpty;

  static void clearTasks() {
    loadingItems.clear();
  }

  ImageManager._create();

  final dio = logDio(BaseOptions())
    ..interceptors.add(CookieManagerSql(SingleInstanceCookieJar.instance!));

  /// 获取图片, 适用于没有任何限制的图片链接
  Stream<DownloadProgress> getImage(final String url, [Map<String, String>? headers]) async* {
    int timeout = 50;
    while (loadingItems[url] != null) {
      var progress = loadingItems[url]!;
      yield progress;
      if (progress.finished) return;
      await Future.delayed(const Duration(milliseconds: 300));
      timeout--;
      if (timeout == 0) {
        loadingItems.remove("url");
      }
    }
    loadingItems[url] = DownloadProgress(0, 1, url, "");
    CachingFile? caching;

    try {
      final key = url;
      var cache = await CacheManager().findCache(key);
      if(cache != null){
        yield DownloadProgress(1, 1, url, cache);
        loadingItems.remove(url);
        return;
      }

      final cachingFile = await CacheManager().openWrite(key);
      caching = cachingFile;
      final savePath = cachingFile.file.path;
      yield DownloadProgress(0, 100, url, savePath);
      headers = headers ?? {};
      headers["User-Agent"] ??= webUA;
      headers["Connection"] = "keep-alive";
      var realUrl = url;
      if(url.contains("s.exhentai.org")){
        // s.exhentai.org 有严格的加载限制
        realUrl = url.replaceFirst("s.exhentai.org", "ehgt.org");
      }
      var dioRes = await dio.get<ResponseBody>(realUrl,
          options: Options(
              responseType: ResponseType.stream, headers: headers));
      if (dioRes.data == null) {
        throw Exception("Empty Data");
      }
      List<int> imageData = [];
      int? expectedBytes;
      try {
        expectedBytes =
            int.parse(dioRes.data!.headers["Content-Length"]![0]) + 1;
      } catch (e) {
        //忽略
      }
      await for (var res in dioRes.data!.stream) {
        imageData.addAll(res);
        await cachingFile.writeBytes(res);
        var progress = DownloadProgress(imageData.length,
            expectedBytes ?? (imageData.length + 1), url, savePath);
        yield progress;
        loadingItems[url] = progress;
      }
      await cachingFile.close();
      yield DownloadProgress(1, 1, url, savePath, Uint8List.fromList(imageData));
    } catch (e, s) {
      caching?.cancel();
      log("$e\n$s", "Network", LogLevel.error);
      rethrow;
    } finally {
      loadingItems.remove(url);
    }
  }

  Stream<DownloadProgress> getEhImageNew(
      final Gallery gallery, final int page) async* {
    final galleryLink = gallery.link;
    final cacheKey = "$galleryLink$page";
    final gid = getGalleryId(galleryLink);

    // check whether this image is loading
    while (loadingItems[cacheKey] != null) {
      var progress = loadingItems[cacheKey]!;
      yield progress;
      if (progress.finished) return;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    loadingItems[cacheKey] = DownloadProgress(0, 1, cacheKey, "");

    CachingFile? caching;

    try {
      final key = cacheKey;
      var cache = await CacheManager().findCache(key);
      if(cache != null){
        yield DownloadProgress(1, 1, key, cache);
        loadingItems.remove(key);
        return;
      }

      final cachingFile = await CacheManager().openWrite(key);
      caching = cachingFile;
      final savePath = cachingFile.file.path;
      yield DownloadProgress(0, 100, key, savePath);

      final options = BaseOptions(
          followRedirects: true,
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 20),
          headers: {"user-agent": webUA, "cookie": EhNetwork().cookiesStr});

      var dio = logDio(options);

      // Get imgKey
      final readerLink =  (await EhNetwork().getReaderLink(galleryLink, page)).data;

      Future<void> getShowKey() async {
        while (gallery.auth!["showKey"] == "loading") {
          await Future.delayed(const Duration(milliseconds: 100));
        }
        if (gallery.auth!["showKey"] != null || gallery.auth!["mpvKey"] != null) {
          return;
        }
        gallery.auth!["showKey"] = "loading";
        try {
          var res = await EhNetwork().request(readerLink);

          var html = parse(res.data);
          var script = html
              .querySelectorAll("script")
              .firstWhereOrNull((element) => element.text.contains("showkey"));
          if(script != null) {
            var match = RegExp(r'showkey="(.*?)"').firstMatch(script.text);
            final showKey = match!.group(1)!;
            gallery.auth!["showKey"] = showKey;
          } else {
            final script = html
                .querySelectorAll("script")
                .firstWhereOrNull((element) => element.text.contains("mpvkey"))?.text;
            if(script == null){
              throw Exception("Failed to get showKey or mpvkey");
            }
            var mpvKey= script.split(";").firstWhere((element) => element.contains("mpvkey"));
            gallery.auth!["mpvKey"] = mpvKey.removeAllBlank
                .replaceFirst("varmpvkey=", "").replaceAll('"', "");
            var imageListScript = script.split(";").firstWhere((element) => element.contains("imagelist"))
                .removeAllBlank.replaceFirst("varimagelist=", "");
            gallery.auth!["imgKey"] = jsonDecode(imageListScript).map((e) => e["k"]).join(",");
            gallery.auth!.remove("showKey");
          }
        }
        catch(e){
          gallery.auth!.remove("showKey");
          rethrow;
        }
      }
      await getShowKey();
      assert(gallery.auth?["showKey"] != null || gallery.auth?["mpvKey"] != null);

      yield DownloadProgress(0, 100, cacheKey, savePath);

      Response<ResponseBody>? res;

      var imgKey = readerLink.split('/')[4];

      if(gallery.auth?["mpvKey"] != null){
        Future<(String image, String nl)> getImageFromApi([String? nl]) async{
          Res<String>? apiRes = await EhNetwork().apiRequest({
            "gid": int.parse(gid),
            "imgkey": gallery.auth!["imgKey"]!.split(',')[page-1],
            "method": "imagedispatch",
            "page": page,
            "mpvkey": gallery.auth!["mpvKey"],
            if(nl != null)
              "nl": nl
          });
          var apiJson = const JsonDecoder().convert(apiRes.data);
          return (apiJson["i"].toString(), apiJson["s"].toString());
        }
        var (image, nl) = await getImageFromApi();
        int retryTimes = 0;
        while(res == null){
          try{
            if(image == ""){
              throw "empty url";
            }
            res = await dio.get<ResponseBody>(image,
                options: Options(responseType: ResponseType.stream));
            if (res.data!.headers["Content-Type"]?[0] == "text/html; charset=UTF-8" ||
                res.data!.headers["content-type"]?[0] == "text/html; charset=UTF-8") {
              throw ImageExceedError();
            }
          }
          catch(e){
            retryTimes++;
            if(retryTimes == 4){
              throw "Failed to load image.\nMaximum number of retries reached.";
            }
            (image, nl) = await getImageFromApi(nl);
          }
        }
      } else {
        Future<(String, String, String?)> getImageFromApi() async{
          // get image url through api
          Res<String>? apiRes = await EhNetwork().apiRequest({
            "gid": int.parse(gid),
            "imgkey": imgKey,
            "method": "showpage",
            "page": page,
            "showkey": gallery.auth!["showKey"]
          });

          if(apiRes.error && apiRes.errorMessage!.contains("handshake")){
            throw "Failed to make api request.\n"
                "This may be due to too frequent requests.\n"
                "Try to wait for some time and retry.";
          }

          var apiJson = const JsonDecoder().convert(apiRes.data);

          var i6 = apiJson["i6"] as String;

          RegExp regex = RegExp(r"nl\('(.+?)'\)");
          var nl = regex.firstMatch(i6)?.group(1);

          var originImage = i6.split("<a href=\"").last.split("\">").first;

          var image = apiJson["i3"] as String;

          image = image.substring(
              image.indexOf("src=\"") + 5, image.indexOf("\" style") - 1);

          return (image, originImage, nl);
        }

        Future<(String, String, String?)> getImageFromHtml() async{
          var res = await EhNetwork().request(readerLink);
          if(res.error){
            throw res.errorMessage ?? "error";
          }else{
            var document = parse(res.data);
            var image = document.querySelector("div#i3 > a > img")?.attributes["src"];
            var nl = document.querySelector("div#i6 > div > a#loadfail")?.attributes["onclick"]?.split('\'')
                .firstWhereOrNull((element) => element.contains('-'));
            var originImage = document.querySelectorAll("div#i6 > div > a")
                .firstWhereOrNull((element) => element.text.contains("original"))
                ?.attributes["href"] ?? "";
            return (image ?? "", originImage, nl);
          }
        }

        String image, originImage;
        String? nl;

        try{
          (image, originImage, nl) = await getImageFromApi();
        }
        catch(e){
          (image, originImage, nl) = await getImageFromHtml();
        }

        if (image.contains("/img/509.gi")) {
          throw ImageExceedError();
        }

        if(appdata.settings[29] == "1" && originImage.isURL){
          image = originImage;
        }

        int retryTimes = 0;

        while(res == null){
          try{
            if(image == ""){
              throw "empty url";
            }
            res = await dio.get<ResponseBody>(image,
                options: Options(responseType: ResponseType.stream));
            if (res.data!.headers["Content-Type"]?[0] == "text/html; charset=UTF-8" ||
                res.data!.headers["content-type"]?[0] == "text/html; charset=UTF-8") {
              throw ImageExceedError();
            }
          }
          catch(e){
            retryTimes++;
            if(retryTimes == 4){
              throw "Failed to load image.\nMaximum number of retries reached.";
            }
            if(nl == null){
              rethrow;
            }
            var (newImage, newNl) = await EhNetwork().getImageLinkWithNL(
                getGalleryId(galleryLink), imgKey, page, nl);
            image = newImage;
            if(kDebugMode){
              print("Get new image: $image, new nl $newNl");
            }
            if(newNl != null){
              nl = newNl;
            }
          }
        }
      }

      var stream = res.data!.stream;
      int? expectedBytes;
      try {
        expectedBytes = int.parse(res.data!.headers["Content-Length"]![0]);
      } catch (e) {
        try {
          expectedBytes = int.parse(res.data!.headers["content-length"]![0]);
        } catch (e) {
          // ignore
        }
      }
      var currentBytes = 0;

      List<int> data = [];
      await for (var b in stream) {
        cachingFile.writeBytes(b);
        currentBytes += b.length;
        data.addAll(b);
        var progress = DownloadProgress(currentBytes,
            (expectedBytes ?? currentBytes) + 1, cacheKey, savePath);
        yield progress;
        loadingItems[cacheKey] = progress;
      }
      await cachingFile.close();
      yield DownloadProgress(1, 1, cacheKey, savePath, Uint8List.fromList(data));
    }
    catch(e, s){
      caching?.cancel();
      LogManager.addLog(LogLevel.error, "Network", "$e\n$s");
    }finally {
      loadingItems.remove(cacheKey);
    }
  }

  ///为Hitomi设计的图片加载函数
  ///
  /// 使用hash标识图片
  Stream<DownloadProgress> getHitomiImage(
      HitomiFile image, String galleryId) async* {
    while (loadingItems[image.hash] != null) {
      var progress = loadingItems[image.hash]!;
      yield progress;
      if (progress.finished) return;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    loadingItems[image.hash] = DownloadProgress(0, 1, image.hash, "");
    CachingFile? caching;

    try {
      final key = image.hash;
      var cache = await CacheManager().findCache(key);
      if(cache != null){
        yield DownloadProgress(1, 1, key, cache);
        loadingItems.remove(key);
        return;
      }

      final cachingFile = await CacheManager().openWrite(key);
      caching = cachingFile;
      final savePath = cachingFile.file.path;
      yield DownloadProgress(0, 100, key, savePath);

      final gg = GG();
      var url = await gg.urlFromUrlFromHash(galleryId, image, 'webp', null);
      int l;
      for (l = url.length - 1; l >= 0; l--) {
        if (url[l] == '.') {
          break;
        }
      }
      var dio = logDio();
      dio.options.headers = {
        "User-Agent": webUA,
        "Referer": "https://hitomi.la/reader/$galleryId.html"
      };

      var res = await dio.get<ResponseBody>(url,
          options: Options(responseType: ResponseType.stream));
      var stream = res.data!.stream;
      int? expectedBytes;
      try {
        expectedBytes = int.parse(res.data!.headers["Content-Length"]![0]);
      } catch (e) {
        try {
          expectedBytes = int.parse(res.data!.headers["content-length"]![0]);
        } catch (e) {
          //忽视
        }
      }
      var currentBytes = 0;
      var data = <int>[];
      await for (var b in stream) {
        data.addAll(b);
        cachingFile.writeBytes(b);
        currentBytes += b.length;
        var progress = DownloadProgress(
            currentBytes, expectedBytes ?? (currentBytes + 1), url, savePath);
        yield progress;
        loadingItems[image.hash] = progress;
      }
      await cachingFile.close();
      yield DownloadProgress(currentBytes, currentBytes, url, savePath,
          Uint8List.fromList(data));
    } catch (e) {
      caching?.cancel();
      rethrow;
    } finally {
      loadingItems.remove(image.hash);
    }
  }

  ///获取禁漫图片, 如果缓存中没有, 则尝试下载
  Stream<DownloadProgress> getJmImage(String url, Map<String, String>? headers,
      {required String epsId,
      required String scrambleId,
      required String bookId}) async* {
    bookId = bookId.replaceAll(RegExp(r"\..+"), "");
    final urlWithoutParam = url.replaceAll(RegExp(r"\?.+"), "");
    while (loadingItems[urlWithoutParam] != null) {
      var progress = loadingItems[urlWithoutParam]!;
      yield progress;
      if (progress.finished) return;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    loadingItems[urlWithoutParam] = DownloadProgress(0, 1, url, "");
    CachingFile? caching;

    try {
      final key = urlWithoutParam;
      var cache = await CacheManager().findCache(key);
      if(cache != null){
        yield DownloadProgress(1, 1, url, cache);
        loadingItems.remove(url);
        return;
      }

      final cachingFile = await CacheManager().openWrite(key);
      caching = cachingFile;
      final savePath = cachingFile.file.path;
      yield DownloadProgress(0, 1, url, savePath);

      var dio = logDio();

      var bytes = <int>[];
      try {
        var res = await dio.get<ResponseBody>(url,
            options: Options(responseType: ResponseType.stream, headers: {
              "User-Agent":
                  "Mozilla/5.0 (Linux; Android 13; WD5DDE5 Build/TQ1A.230205.002; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/114.0.5735.196 Safari/537.36",
              "x-requested-with": "com.jiaohua_browser",
              "referer": "https://www.jmapibranch2.cc/"
            }));
        var stream = res.data!.stream;
        int i = 0;
        await for (var b in stream) {
          //不直接写入文件, 因为需要对图片进行重组, 处理完成后再写入
          bytes.addAll(b.toList());
          //构建虚假的进度条, 因为无法获取jm文件大小
          i = min(600, bytes.length ~/ 5000);
          var progress = DownloadProgress(i, 1000, url, savePath);
          yield progress;
          loadingItems[urlWithoutParam] = progress;
        }
      } catch (e) {
        rethrow;
      }
      var progress = DownloadProgress(750, 1000, url, savePath);
      yield progress;
      loadingItems[urlWithoutParam] = progress;
      if (url.split('.').last != "gif") {
        bytes = await startRecombineAndWriteImage(
            Uint8List.fromList(bytes), epsId, scrambleId, bookId, savePath);
      }
      await cachingFile.writeBytes(bytes);
      await cachingFile.close();
      progress = DownloadProgress(1, 1, url, savePath, Uint8List.fromList(bytes));
      yield progress;
    } catch (e) {
      caching?.cancel();
      rethrow;
    } finally {
      loadingItems.remove(urlWithoutParam);
    }
  }

  Future<File?> getFile(String key) async {
    var cache = await CacheManager().findCache(key);
    if(cache != null){
      return File(cache);
    }
    return null;
  }

  Future<void> clear() async {
    await CacheManager().clear();
  }

  Future<bool> find(String key) async {
    return await CacheManager().findCache(key) != null;
  }

  Future<void> delete(String key) async {
    await CacheManager().delete(key);
  }
}

class DownloadProgress {
  final int _currentBytes;
  final int _expectedBytes;
  final String url;
  final String savePath;
  final Uint8List? data;

  int get currentBytes => _currentBytes;
  int get expectedBytes => _expectedBytes;
  bool get finished => _currentBytes == _expectedBytes;

  const DownloadProgress(
      this._currentBytes, this._expectedBytes, this.url, this.savePath, [this.data]);

  File getFile() => File(savePath);
}

class ImageExceedError extends Error {
  @override
  String toString() => "Maximum image loading limit reached.";
}
