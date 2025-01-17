// mde_flutter - A cross platform viewer for the mods.de forum.
// Copyright (C) 2019  Sebastian Uhl
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:xml/xml.dart' as xml;

import 'mde_account.dart';
import 'mde_bbcode_parser.dart';
import 'mde_bender_cache.dart';
import 'mde_codec.dart';
import 'mde_exceptions.dart';
import 'mde_icons.dart';
import 'template_filler.dart';

class Thread with TemplateFiller {
  final String templateFile = 'assets/thread.html';

  final int threadId;
  final int threadPage;
  final int postId;

  Thread({
    @required this.threadId,
    this.threadPage,
    this.postId,
  }) {
    if (threadPage != null && postId != null) {
      throw ArgumentError(
          'at least one of "threadPage" or "postId" must be null');
    }

    _fetchThread();
  }

  _fetchThread() async {
    debugPrint(Uri.https(
      'forum.mods.de',
      'bb/xml/thread.php',
      {
        'TID': threadId.toString(),
        'page': threadPage.toString(),
        'PID': postId.toString(),
        'update_bookmark': 1.toString(),
      },
    ).toString());

    final Cookie sessionCookie = await MDEAccount.sessionCookie();

    HttpClient httpClient = HttpClient();
    HttpClientRequest request = await httpClient.getUrl(Uri.https(
      'forum.mods.de',
      'bb/xml/thread.php',
      {
        'TID': threadId.toString(),
        'page': threadPage.toString(),
        'PID': postId.toString(),
        'update_bookmark': 1.toString(),
      },
    ));
    if (sessionCookie != null) {
      request.cookies.add(sessionCookie);
    }
    HttpClientResponse response = await request.close();

    if (response.statusCode == 200) {
      // update session cookie
      if (sessionCookie != null) {
        // keep the last cookie for MDESID
        Cookie cookie = response.cookies.lastWhere((Cookie cookie) {
          return cookie.name == 'MDESID';
        });

        await MDEAccount.updateSessionCookie(cookie);
      }

      // if the call to the server was successful, parse the XML
      // the mods.de server encodes the XML document in UTF-8, but does not
      // specify this in the HTTP header so that the http package uses latin1 for
      // the decoding causing trouble with umlauts
      // the XML document currently specifies UTF-8 so this is hard-coded here
      final xml.XmlDocument document =
          xml.parse(await response.transform(mdeXmlDecoder).join());

      Map<String, Object> threadInfo = {
        'threadId': threadId,
        'posts': [],
        'initialAnchor': postId != null,
        'initialPostId': postId,
      };

      // the XML document should only contain one rootElement 'board'
      final xml.XmlElement thread = document.rootElement;
      if (thread.name.qualified != 'thread') {
        throw Exception('Unexpected content!');
      }

      threadInfo['currentUserId'] =
          int.parse(thread.getAttribute('current-user-id'));
      threadInfo['isLoggedIn'] = threadInfo['currentUserId'] != 0;

      threadInfo['id'] = int.parse(thread.getAttribute('id'));

      // the element 'thread' should contain an element 'title'
      var candidates = thread.findElements('title');
      if (candidates.length != 1) {
        throw Exception('title element missing from thread!');
      }
      final String threadName = candidates.first.text;
      threadInfo['threadTitle'] = threadName;

      // the element 'thread' should contain an element 'subtitle'
      candidates = thread.findElements('subtitle');
      if (candidates.length != 1) {
        throw Exception('subtitle element missing from thread!');
      }
      threadInfo['subtitle'] = candidates.first.text;

      candidates = thread.findElements('number-of-pages');
      if (candidates.length != 1) {
        throw Exception('number-of-pages element missing from thread');
      }
      final int nrPages = int.parse(candidates.first.getAttribute('value'));
      threadInfo['threadNrPages'] = nrPages;

      // the element 'thread' should contain an element 'token-newreply' for
      // logged in users
      candidates = thread.findElements('token-newreply');
      if (candidates.length != 0) {
        if (candidates.length != 1) {
          throw Exception('token-newreply element missing from post!');
        }
        threadInfo['canCreatePost'] = true;
        threadInfo['newReplyToken'] = candidates.first.getAttribute('value');
      } else {
        threadInfo['canCreatePost'] = false;
      }

      // the element 'posts' should contain an element 'thread'
      candidates = thread.findElements('posts');
      if (candidates.length != 1) {
        throw Exception('posts element missing from thread!');
      }
      final xml.XmlElement posts = candidates.first;

      threadInfo['threadPage'] = int.parse(posts.getAttribute('page'));
      threadInfo['isLastPage'] = nrPages == threadInfo['threadPage'];

      if (int.parse(posts.getAttribute('count')) == 0) {
        content.completeError(EmptyThreadPage(
          threadId: threadId,
          threadName: threadName,
          threadPage: threadInfo['threadPage'],
        ));
        return;
      }

      Map<String, Future<String>> avatarLoaders = Map<String, Future<String>>();
      List<Future<void>> avatarSetters = List<Future<void>>();

      // loop over posts to get each individual post
      for (final xml.XmlElement post in posts.children) {
        Map<String, Object> postInfo = {};

        postInfo['id'] = int.parse(post.getAttribute('id'));
        postInfo['validId'] = postInfo['id'] != 0;

        // the element 'post' should contain an element 'user'
        candidates = post.findElements('user');
        if (candidates.length != 1) {
          throw Exception('user element missing from post!');
        }
        final xml.XmlElement user = candidates.first;
        postInfo['author'] = user.text;
        postInfo['authorId'] = int.parse(user.getAttribute('id'));

        postInfo['getAuthorLocked'] = user.getAttribute('locked') != null;

        // the element 'post' should contain an element 'avatar'
        candidates = post.findElements('avatar');
        if (candidates.length != 1) {
          throw Exception('avatar element missing from post!');
        }
        final xml.XmlElement avatar = candidates.first;
        if (avatar.attributes.length == 0 && avatar.children.length == 0) {
          postInfo['avatar'] = '';
          postInfo['avatarId'] = 0;
          postInfo['avatarBackground'] = '';
        } else {
          postInfo['avatar'] = avatar.text;
          postInfo['avatarId'] = int.parse(avatar.getAttribute('id'));

          if (!avatarLoaders.containsKey(avatar.text)) {
            avatarLoaders[avatar.text] = mdeBenderCache.html(avatar.text);
          }

          avatarSetters.add(
            avatarLoaders[avatar.text].then(
              (final String avatarBackground) {
                postInfo['avatarBackground'] = avatarBackground;
              },
            ),
          );
        }

        // the element 'post' should contain an element 'date'
        candidates = post.findElements('date');
        if (candidates.length != 1) {
          throw Exception('date element missing from post!');
        }
        final DateTime date = DateTime.fromMillisecondsSinceEpoch(
            int.parse(candidates.first.getAttribute('timestamp')) * 1000);
        final DateFormat dateFormat = DateFormat('dd.MM.yyyy, HH:mm');
        postInfo['date'] = dateFormat.format(date);

        // the element 'post' should contain an element 'icon'
        candidates = post.findElements('icon');
        if (candidates.length != 0) {
          if (candidates.length != 1) {
            throw Exception('icon element missing from post!');
          }
          final int id = int.parse(candidates.first.getAttribute('id'));
          postInfo['icon'] = mdeIcons[id]?.postIcon ?? MDEBrokenIcon().postIcon;
        } else {
          postInfo['icon'] = '';
        }

        // the element 'post' should contain an element 'message'
        candidates = post.findElements('message');
        if (candidates.length != 1) {
          throw Exception('message element missing from post!');
        }
        final xml.XmlElement message = candidates.first;

        // the element 'message' should contain an element 'title'
        candidates = message.findElements('title');
        if (candidates.length != 1) {
          throw Exception('title element missing from message!');
        }
        postInfo['title'] = candidates.first.text;

        // the element 'message' should contain an element 'content'
        candidates = message.findElements('content');
        if (candidates.length != 1) {
          throw Exception('content element missing from message!');
        }
        postInfo['text'] =
            MDEBBCodeParser().parse(candidates.first.text).toHtml();

        // the element 'message' should contain an element 'edited'
        candidates = message.findElements('edited');
        if (candidates.length != 1) {
          throw Exception('edited element missing from message!');
        }
        final xml.XmlElement edited = candidates.first;

        postInfo['numEdited'] = int.parse(edited.getAttribute('count'));
        postInfo['isEdited'] = postInfo['numEdited'] != 0;
        if (postInfo['isEdited']) {
          // in case of an edited post:
          // the element 'edited' should contain an element 'lastedit'
          candidates = edited.findElements('lastedit');
          if (candidates.length != 1) {
            throw Exception('lastedit element missing from edited!');
          }
          final xml.XmlElement lastedit = candidates.first;

          // the element 'lastedit' should contain an element 'user'
          candidates = lastedit.findElements('user');
          if (candidates.length != 1) {
            throw Exception('user element missing from lastedit!');
          }
          postInfo['lastEditUser'] = candidates.first.text;

          // the element 'lastedit' should contain an element 'date'
          candidates = lastedit.findElements('date');
          if (candidates.length != 1) {
            throw Exception('date element missing from lastedit!');
          }
          final DateTime date = DateTime.fromMillisecondsSinceEpoch(
              int.parse(candidates.first.getAttribute('timestamp')) * 1000);
          final DateFormat dateFormat = DateFormat('dd.MM.yyyy, HH:mm');
          postInfo['lastEditDate'] = dateFormat.format(date);
        }

        // when logged in the element 'post' should contain an element
        // 'token-setbookmark'
        candidates = post.findElements('token-setbookmark');
        if (candidates.length != 0) {
          if (candidates.length != 1) {
            throw Exception('token-setbookmark element missing from post!');
          }
          postInfo['canSetBookmarkToken'] = true;
          postInfo['setBookmarkToken'] = candidates.first.getAttribute('value');
        } else {
          postInfo['canSetBookmarkToken'] = false;
        }

        // if the post was created by the current user, the element 'post'
        // // should contain an element 'token-editreply'
        candidates = post.findElements('token-editreply');
        if (candidates.length != 0) {
          if (candidates.length != 1) {
            throw Exception('token-editreply element missing from post!');
          }
          postInfo['canEditPost'] = true;
          postInfo['editReplyToken'] = candidates.first.getAttribute('value');
        } else {
          postInfo['canEditPost'] = false;
        }

        postInfo['showPostMenu'] = threadInfo['isLoggedIn'] &&
            (postInfo['canSetBookmarkToken'] ||
                postInfo['canSetBookmarkToken'] ||
                (postInfo['validId'] && threadInfo['canCreatePost']));

        List posts = threadInfo['posts'];
        posts.add(postInfo);
      }

      await Future.wait(avatarLoaders.values);
      await Future.wait(avatarSetters);

      content.complete(threadInfo);
    } else {
      response.drain();

      // If that call was not successful, throw an error.
      throw Exception('Failed to load post');
    }
  }
}
