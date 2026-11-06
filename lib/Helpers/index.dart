// ignore_for_file: depend_on_referenced_packages, use_build_context_synchronously

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:id3tag/id3tag.dart';
import '../player/widgets/delete_window.dart';
import '/exports/exports.dart';

import '../Routes/routes.dart';
import '../controllers/app_controller.dart';

String tempPath = "";

Future<void> fetchArtwork(
  String path,
  int id, {
  ArtworkType type = ArtworkType.AUDIO,
  String other = "",
  int quality = 70,
  int size = 200,
}) async {
  String tempPath = "";

  var tempDir = await getTemporaryDirectory();
  tempPath = tempDir.path;
  // }

  String imagePath = "";

  Future<Directory> createDirectory(Directory dir) async {
    // log("${dir.path}  exist ${dir.existsSync()}");
    if (dir.existsSync() == false) {
      dir.createSync();
      return dir;
    }
    return dir;
  }

  String getArtworkImagePath() {
    if (path.isEmpty && other.isNotEmpty) {
      return "$tempPath/${other.replaceAll(RegExp(r'[ /|:]'), '_')}.png";
    } else {
      return "$tempPath/${path.split('/').last.split('.').first}.png";
    }
  }
  // function to fetch saveImage Urls

  Future<void> saveArtworkImage(String imgPath, String original) async {
    try {
      if (!File(imgPath).existsSync()) {
        if (type == ArtworkType.ALBUM ||
            type == ArtworkType.ARTIST ||
            type == ArtworkType.GENRE) {
          var artworkData = await OnAudioQuery().queryArtwork(
            id,
            type,
            quality: quality,
            size: 500,
          );
          if (artworkData != null && artworkData.isNotEmpty) {
            await File(imgPath).writeAsBytes(artworkData);
          }
        } else if (type == ArtworkType.AUDIO) {
          if (File(original).existsSync()) {
            var parser = ID3TagReader.path(original);
            var tag = await parser.readTag();
            var artworkData = tag.pictures;
            if (tempPath.isNotEmpty && artworkData.isNotEmpty) {
              await File(imgPath).writeAsBytes(artworkData.first.imageData);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error saving artwork: $e');
    }
  }

  Directory albumPath = await createDirectory(Directory("$tempPath/Albums"));
  Directory artistPath = await createDirectory(Directory("$tempPath/Artists"));
  Directory genrePath = await createDirectory(Directory("$tempPath/Genres"));
  // check if all custom directories exist
  // log("Albums ${albumPath.existsSync()}");
  // log("Genres ${genrePath.existsSync()}");
  // log("Artists ${artistPath.existsSync()}");

  if (path.isEmpty && other != "Unknown") {
    if (type == ArtworkType.ALBUM) {
      imagePath =
          "${albumPath.path}/${other.replaceFirst(' ', '_').replaceFirst('/', '_')}.png";
    } else if (type == ArtworkType.ARTIST) {
      imagePath =
          "${artistPath.path}/${other.replaceFirst(' ', '_').replaceFirst('/', '_')}.png";
    } else if (type == ArtworkType.GENRE) {
      imagePath =
          "${genrePath.path}/${other.replaceFirst(' ', '_').replaceFirst('/', '_')}.png";
    }
  } else {
    imagePath = getArtworkImagePath();
  }

  // if (File(path).existsSync() == true) {
  await saveArtworkImage(imagePath, path);
  // }
}

/// Decode-size-aware artwork provider. [decodeWidth] is the physical pixel
/// width the image will be shown at; embedded covers can be 1500-3000px
/// (~36MB RGBA decoded), so decoding at display size is the difference
/// between a 100KB and a 30MB bitmap for a list tile.
Future<ImageProvider<Object>> savedImage(
  String path,
  int id, {
  ArtworkType type = ArtworkType.AUDIO,
  String other = "",
  int quality = 70,
  int size = 200,
  int? decodeWidth,
}) async {
  String tempPath = "";
  String imagePath = "";

  ImageProvider fileProvider(String p) {
    final base = FileImage(File(p));
    if (decodeWidth == null) return base;
    return ResizeImage(base, width: decodeWidth, policy: ResizeImagePolicy.fit);
  }

  var tempDir = await getTemporaryDirectory();
  tempPath = tempDir.path;

  // Cloud files: use stable cloud_art_{id}.png naming
  if (path.startsWith('http')) {
    imagePath = "$tempPath/cloud_art_$id.png";
    return await File(imagePath).exists()
        ? fileProvider(imagePath)
        : const AssetImage("assets/audio.jpeg") as ImageProvider;
  }

  String getArtworkImagePath() {
    if (path.isEmpty && other.isNotEmpty) {
      return "$tempPath/${other.replaceAll(RegExp(r'[ /|:]'), '_')}.png";
    } else {
      return "$tempPath/${path.split('/').last.split('.').first}.png";
    }
  }

  if (path.isEmpty && other != "Unknown") {
    if (type == ArtworkType.ALBUM) {
      imagePath =
          "$tempPath/Albums/${other.replaceFirst(' ', '_').replaceFirst('/', '_')}.png";
    } else if (type == ArtworkType.ARTIST) {
      imagePath =
          "$tempPath/Artists/${other.replaceFirst(' ', '_').replaceFirst('/', '_')}.png";
    } else if (type == ArtworkType.GENRE) {
      imagePath =
          "$tempPath/Genres/${other.replaceFirst(' ', '_').replaceFirst('/', '_')}.png";
    }
  } else {
    imagePath = getArtworkImagePath();
  }
  return await File(imagePath).exists()
      ? fileProvider(imagePath)
      : const AssetImage("assets/audio.jpeg") as ImageProvider;
}

// function to fetch saved artwork to work on the notification
Future<String> fetchArtworkUrl(
  String path,
  int id, {
  ArtworkType type = ArtworkType.AUDIO,
  String other = "",
  int quality = 90,
  int size = 400,
}) async {
  final tempDir = await getTemporaryDirectory();
  final tempPath = tempDir.path;

  // Cloud files: use stable cloud_art_{id}.png naming
  if (path.startsWith('http')) {
    final cloudArt = "$tempPath/cloud_art_$id.png";
    final dirD = Directory("$tempPath/Default");
    if (!dirD.existsSync()) {
      await dirD.create(recursive: true);
      final defaultImg = await rootBundle.load("assets/audio.jpeg");
      await File(
        "${dirD.path}/default.png",
      ).writeAsBytes(defaultImg.buffer.asUint8List());
    }
    return File(cloudArt).existsSync() ? cloudArt : "${dirD.path}/default.png";
  }

  String imagePath = "";

  String getArtworkImagePath() {
    if (path.isEmpty && other.isNotEmpty && other != "Unknown") {
      return "$tempPath/${other.replaceAll(RegExp(r'[ /]'), '_')}.png";
    } else {
      return "$tempPath/${path.split('/').last.split('.').first}.png";
    }
  }

  imagePath = getArtworkImagePath();
  final dirD = Directory("$tempPath/Default");
  if (!dirD.existsSync()) {
    await dirD.create(recursive: true);
    final defaultImg = await rootBundle.load("assets/audio.jpeg");
    await File(
      "${dirD.path}/default.png",
    ).writeAsBytes(defaultImg.buffer.asUint8List());
  }

  return File(imagePath).existsSync() ? imagePath : "${dirD.path}/default.png";
}

/// show snackbar message
/// @param type = 'danger' | 'info' | warning
///
///
void showMessage({
  String type = 'info',
  String? msg,
  bool float = false,
  required BuildContext context,
  double opacity = 1,
  int duration = 5,
  Animation<double>? animation,
}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      behavior: float ? SnackBarBehavior.floating : SnackBarBehavior.fixed,
      content: Text(msg ?? ''),
      backgroundColor: type == 'info'
          ? Theme.of(context).colorScheme.primary
          : type == 'warning'
          ? const Color.fromARGB(255, 255, 155, 73).withValues(alpha: opacity)
          : type == 'danger'
          ? const Color.fromARGB(255, 247, 68, 68).withValues(alpha: opacity)
          : type == 'success'
          ? const Color.fromARGB(255, 20, 238, 31).withValues(alpha: opacity)
          : Colors.grey[600]!.withValues(alpha: opacity),
      duration: Duration(seconds: duration),
    ),
  );
}

// show add playlist widget
void showAddPlaylist(
  TextEditingController textController,
  AppController controller,
  BuildContext context,
) {
  showAdaptiveDialog(
    context: context,
    builder: (context) {
      return SimpleDialog(
        title: const Text("Create playlist"),
        children: [
          TextField(
            showCursor: true,
            autofocus: true,
            controller: textController,
            decoration: const InputDecoration(hintText: "Enter playlist name"),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  final name = textController.text.trim();
                  if (name.isNotEmpty &&
                      !RegExp(r'[\\/:*?"<>|]').hasMatch(name)) {
                    controller.audioQuery.createPlaylist(name).then((value) {
                      if (value) {
                        // controller.audioQuery.addToPlaylist()
                        showMessage(
                          context: context,
                          float: true,
                          type: "success",
                          msg: "${textController.text} created successfully",
                        );
                        textController.clear();
                        Routes.pop(context);
                      }
                    });
                  } else {
                    showMessage(
                      context: context,
                      float: true,
                      msg: name.isEmpty
                          ? "Playlist name is required"
                          : "Playlist name contains invalid characters",
                    );
                  }
                },
                child: const Text("Create"),
              ),
              TextButton(
                onPressed: () => Routes.pop(context),
                child: const Text("Cancel"),
              ),
            ],
          ),
        ],
      );
    },
  );
}

void showDeletePlaylist(
  AppController controller,
  String playlist,
  int playlistId,
  BuildContext context,
) {
  showAdaptiveDialog(
    context: context,
    builder: (context) {
      return AlertDialog.adaptive(
        title: const Text("Remove playlist!!"),
        content: Text("Are you sure you want to remove $playlist"),
        actions: [
          TextButton(
            onPressed: () => Routes.pop(context),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () {
              Routes.pop(context);
              controller.audioQuery.removePlaylist(playlistId).then((value) {
                if (value) {
                  showMessage(
                    context: context,
                    msg: "$playlist removed successfully",
                  );
                }
              });
            },
            child: const Text("Delete"),
          ),
        ],
      );
    },
  );
}

final RegExp _durationRegex = RegExp(r'((^0*[1-9]\d*:)?\d{2}:\d{2})\.\d+$');

String formatTime(Duration time) {
  return "${_durationRegex.firstMatch("$time")?.group(1)}";
}

// method to invoke the delete window
void showDeleteWindow(String type, String path, BuildContext context) {
  showModalBottomSheet(
    useRootNavigator: true,
    showDragHandle: true,
    // backgroundColor: Colors.transparent,
    context: context,
    builder: (context) {
      return BottomSheet(
        // backgroundColor: Colors.transparent,
        onClosing: () {},
        builder: (context) {
          return DeleteWindow(type: type, folder: path);
        },
      );
    },
  );
}
