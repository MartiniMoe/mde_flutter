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
import 'mde_codec.dart';
import 'mde_exceptions.dart';
import 'template_filler.dart';

class Boards with TemplateFiller {
  final String templateFile = 'assets/boards.html';

  Boards() {
    _fetchBoards();
  }

  _fetchBoards() async {
    debugPrint(Uri.https(
      'forum.mods.de',
      'bb/xml/boards.php',
    ).toString());

    final Cookie sessionCookie = await MDEAccount.sessionCookie();

    HttpClient httpClient = HttpClient();
    HttpClientRequest request = await httpClient.getUrl(
      Uri.https(
        'forum.mods.de',
        'bb/xml/boards.php',
      ),
    );
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

      Map<String, Object> boardsInfo = {
        'categories': [],
      };

      // the XML document should only contain one rootElement 'categories'
      final xml.XmlElement categories = document.rootElement;
      if (categories.name.qualified != 'categories') {
        throw XmlError.forBoards(
          error: 'Root element needs to be "categories".',
        );
      }

      boardsInfo['currentUserId'] =
          int.parse(categories.getAttribute('current-user-id'));
      boardsInfo['isLoggedIn'] = boardsInfo['currentUserId'] != 0;

      // the element 'categories' should contain an attribute 'count' which should
      // be convertible to an integer, and should agree with the number of
      // children
      final int count = int.parse(categories.getAttribute('count'));
      if (count is! int) {
        throw Exception('Unexpected content!');
      }
      if (count != categories.children.length) {
        throw Exception('Inconsistent count!');
      }

      // loop over categories to get the individual boards
      for (final xml.XmlElement category in categories.children) {
        Map<String, Object> categoryInfo = {
          'boards': [],
        };

        if (category.name.qualified != 'category') {}

        var candidates = category.findElements('name');
        if (candidates.length != 1) {
          throw Exception('name element missing from category!');
        }
        final String catName = candidates.first.text;
        categoryInfo['name'] = catName;

        candidates = category.findElements('description');
        if (candidates.length != 1) {
          throw Exception('description element missing from category!');
        }
        final String catDescription = candidates.first.text;
        categoryInfo['description'] = catDescription;

        candidates = category.findElements('boards');
        if (candidates.length == 0) {
          // no visible boards in this category
          continue;
        }
        if (candidates.length != 1) {
          throw Exception('boards element missing from category!');
        }
        final xml.XmlElement boards = candidates.first;

        for (final xml.XmlElement board in boards.children) {
          Map<String, Object> boardInfo = {};

          if (board.name.qualified != 'board') {
            throw XmlError.forBoards(
              error: 'All child elements of "boards" should be "board".',
            );
          }

          final int boardId = int.parse(board.getAttribute('id'));
          boardInfo['id'] = boardId;

          candidates = board.findElements('name');
          if (candidates.length != 1) {
            throw XmlError.forBoards(
              error:
                  'A "board" element does not contain exactly one "name" child.',
            );
          }
          final String boardName = candidates.first.text;
          boardInfo['name'] = boardName;

          candidates = board.findElements('description');
          if (candidates.length != 1) {
            throw XmlError.forBoards(
              error:
                  'A "board" element does not contain exactly one "description" child.',
            );
          }
          final String boardDescription = candidates.first.text;
          boardInfo['description'] = boardDescription;

          String boardLastPostUser;
          String boardLastPostDate;
          candidates = board.findElements('lastpost');
          if (candidates.length > 0) {
            if (candidates.length != 1) {
              throw Exception('more than one last post!');
            }

            final xml.XmlElement lastPost = candidates.first;

            candidates = lastPost.findElements('post');
            if (candidates.length != 1) {
              XmlError.forBoards(
                error:
                    'A "lastpost" element does not contain exactly one "post" child.',
              );
            }
            final xml.XmlElement lastPostPost = candidates.first;

            candidates = lastPostPost.findElements('user');
            if (candidates.length != 1) {}
            boardLastPostUser = candidates.first.text;

            candidates = lastPostPost.findElements('date');
            if (candidates.length != 1) {}
            final xml.XmlElement lastPostDate = candidates.first;

            final DateTime date = DateTime.fromMillisecondsSinceEpoch(
                int.parse(lastPostDate.getAttribute('timestamp')) * 1000);
            final DateFormat dateFormat = DateFormat('dd.MM.yyyy, HH:mm');
            boardLastPostDate = dateFormat.format(date);
          }
          boardInfo['lastPostUser'] = boardLastPostUser;
          boardInfo['lastPostDate'] = boardLastPostDate;

          List boards = categoryInfo['boards'];
          boards.add(boardInfo);
        }

        List categories = boardsInfo['categories'];
        categories.add(categoryInfo);
      }

      content.complete(boardsInfo);
    } else {
      response.drain();

      // If that call was not successful, throw an error.
      throw Exception('Failed to load post');
    }
  }
}
