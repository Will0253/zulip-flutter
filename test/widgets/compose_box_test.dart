import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_checks/flutter_checks.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/route/channels.dart';
import 'package:zulip/api/route/messages.dart';
import 'package:zulip/model/localizations.dart';
import 'package:zulip/model/narrow.dart';
import 'package:zulip/model/store.dart';
import 'package:zulip/model/typing_status.dart';
import 'package:zulip/widgets/app.dart';
import 'package:zulip/widgets/color.dart';
import 'package:zulip/widgets/compose_box.dart';
import 'package:zulip/widgets/page.dart';
import 'package:zulip/widgets/icons.dart';
import 'package:zulip/widgets/theme.dart';

import '../api/fake_api.dart';
import '../example_data.dart' as eg;
import '../flutter_checks.dart';
import '../model/binding.dart';
import '../model/store_checks.dart';
import '../model/test_store.dart';
import '../model/typing_status_test.dart';
import '../stdlib_checks.dart';
import 'dialog_checks.dart';
import 'test_app.dart';

void main() {
  TestZulipBinding.ensureInitialized();

  late PerAccountStore store;
  late FakeApiConnection connection;
  late ComposeBoxController? controller;

  Future<void> prepareComposeBox(WidgetTester tester, {
    required Narrow narrow,
    User? selfUser,
    List<User> otherUsers = const [],
    List<ZulipStream> streams = const [],
    bool? mandatoryTopics,
    int? zulipFeatureLevel,
  }) async {
    if (narrow case ChannelNarrow(:var streamId) || TopicNarrow(: var streamId)) {
      assert(streams.any((stream) => stream.streamId == streamId),
        'Add a channel with "streamId" the same as of $narrow.streamId to the store.');
    }
    addTearDown(testBinding.reset);
    selfUser ??= eg.selfUser;
    zulipFeatureLevel ??= eg.futureZulipFeatureLevel;
    final selfAccount = eg.account(user: selfUser, zulipFeatureLevel: zulipFeatureLevel);
    await testBinding.globalStore.add(selfAccount, eg.initialSnapshot(
      realmUsers: [selfUser, ...otherUsers],
      streams: streams,
      zulipFeatureLevel: zulipFeatureLevel,
      realmMandatoryTopics: mandatoryTopics,
    ));

    store = await testBinding.globalStore.perAccount(selfAccount.id);

    connection = store.connection as FakeApiConnection;

    await tester.pumpWidget(TestZulipApp(accountId: selfAccount.id,
      child: Column(
        // This positions the compose box at the bottom of the screen,
        // simulating the layout of the message list page.
        children: [
          const Expanded(child: SizedBox.expand()),
          ComposeBox(narrow: narrow),
        ])));
    await tester.pumpAndSettle();

    controller = tester.state<ComposeBoxState>(find.byType(ComposeBox)).controller;
  }

  /// A [Finder] for the topic input.
  ///
  /// To enter some text, use [enterTopic].
  final topicInputFinder = find.byWidgetPredicate(
    (widget) => widget is TextField && widget.controller is ComposeTopicController);

  /// Set the topic input's text to [topic], using [WidgetTester.enterText].
  Future<void> enterTopic(WidgetTester tester, {
    required ChannelNarrow narrow,
    required String topic,
  }) async {
    connection.prepare(body:
      jsonEncode(GetStreamTopicsResult(topics: [eg.getStreamTopicsEntry()]).toJson()));
    await tester.enterText(topicInputFinder, topic);
    check(connection.takeRequests()).single
      ..method.equals('GET')
      ..url.path.equals('/api/v1/users/me/${narrow.streamId}/topics');
  }

  /// A [Finder] for the content input.
  ///
  /// To enter some text, use [enterContent].
  final contentInputFinder = find.byWidgetPredicate(
    (widget) => widget is TextField && widget.controller is ComposeContentController);

  /// Set the content input's text to [content], using [WidgetTester.enterText].
  Future<void> enterContent(WidgetTester tester, String content) async {
    await tester.enterText(contentInputFinder, content);
  }

  void checkContentInputValue(WidgetTester tester, String expected) {
    check(tester.widget<TextField>(contentInputFinder))
      .controller.isNotNull().value.text.equals(expected);
  }

  Future<void> tapSendButton(WidgetTester tester) async {
    connection.prepare(json: SendMessageResult(id: 123).toJson());
    await tester.tap(find.byIcon(ZulipIcons.send));
    await tester.pump(Duration.zero);
  }

  group('ComposeBoxTheme', () {
    test('lerp light to dark, no crash', () {
      final a = ComposeBoxTheme.light;
      final b = ComposeBoxTheme.dark;

      check(() => a.lerp(b, 0.5)).returnsNormally();
    });
  });

  group('ComposeContentController', () {
    group('insertPadded', () {
      // Like `parseMarkedText` in test/model/autocomplete_test.dart,
      //   but a bit different -- could maybe deduplicate some.
      TextEditingValue parseMarkedText(String markedText) {
        final textBuffer = StringBuffer();
        int? insertionPoint;
        int i = 0;
        for (final char in markedText.codeUnits) {
          if (char == 94 /* ^ */) {
            if (insertionPoint != null) {
              throw Exception('Test error: too many ^ in input');
            }
            insertionPoint = i;
            continue;
          }
          textBuffer.writeCharCode(char);
          i++;
        }
        if (insertionPoint == null) {
          throw Exception('Test error: expected ^ in input');
        }
        return TextEditingValue(text: textBuffer.toString(), selection: TextSelection.collapsed(offset: insertionPoint));
      }

      /// Test the given `insertPadded` call, in a convenient format.
      ///
      /// In valueBefore, represent the insertion point as "^".
      /// In expectedValue, represent the collapsed selection as "^".
      void testInsertPadded(String description, String valueBefore, String textToInsert, String expectedValue) {
        test(description, () {
          final controller = ComposeContentController();
          controller.value = parseMarkedText(valueBefore);
          controller.insertPadded(textToInsert);
          check(controller.value).equals(parseMarkedText(expectedValue));
        });
      }

      // TODO(?) exercise the part of insertPadded that chooses the insertion
      //   point based on [TextEditingValue.selection], which may be collapsed,
      //   expanded, or null (what they call !TextSelection.isValid).

      testInsertPadded('empty; insert one line',
        '^', 'a\n',    'a\n\n^');
      testInsertPadded('empty; insert two lines',
        '^', 'a\nb\n', 'a\nb\n\n^');

      group('insert at end', () {
        testInsertPadded('one empty line; insert one line',
          '\n^',     'a\n',    '\na\n\n^');
        testInsertPadded('two empty lines; insert one line',
          '\n\n^',   'a\n',    '\n\na\n\n^');
        testInsertPadded('one line, incomplete; insert one line',
          'a^',      'b\n',    'a\n\nb\n\n^');
        testInsertPadded('one line, complete; insert one line',
          'a\n^',    'b\n',    'a\n\nb\n\n^');
        testInsertPadded('multiple lines, last is incomplete; insert one line',
          'a\nb^',   'c\n',    'a\nb\n\nc\n\n^');
        testInsertPadded('multiple lines, last is complete; insert one line',
          'a\nb\n^', 'c\n',    'a\nb\n\nc\n\n^');
        testInsertPadded('multiple lines, last is complete; insert two lines',
          'a\nb\n^', 'c\nd\n', 'a\nb\n\nc\nd\n\n^');
      });

      group('insert at start', () {
        testInsertPadded('one empty line; insert one line',
          '^\n',     'a\n',    'a\n\n^');
        testInsertPadded('two empty lines; insert one line',
          '^\n\n',   'a\n',    'a\n\n^\n');
        testInsertPadded('one line, incomplete; insert one line',
          '^a',      'b\n',    'b\n\n^a');
        testInsertPadded('one line, complete; insert one line',
          '^a\n',    'b\n',    'b\n\n^a\n');
        testInsertPadded('multiple lines, last is incomplete; insert one line',
          '^a\nb',   'c\n',    'c\n\n^a\nb');
        testInsertPadded('multiple lines, last is complete; insert one line',
          '^a\nb\n', 'c\n',    'c\n\n^a\nb\n');
        testInsertPadded('multiple lines, last is complete; insert two lines',
          '^a\nb\n', 'c\nd\n', 'c\nd\n\n^a\nb\n');
      });

      group('insert in middle', () {
        testInsertPadded('middle of line',
          'a^a\n',       'b\n', 'a\n\nb\n\n^a\n');
        testInsertPadded('start of non-empty line, after empty line',
          'b\n\n^a\n',   'c\n', 'b\n\nc\n\n^a\n');
        testInsertPadded('end of non-empty line, before non-empty line',
          'a^\nb\n',     'c\n', 'a\n\nc\n\n^b\n');
        testInsertPadded('start of non-empty line, after non-empty line',
          'a\n^b\n',     'c\n', 'a\n\nc\n\n^b\n');
        testInsertPadded('text start; one empty line; insertion point; one empty line',
          '\n^\n',       'a\n', '\na\n\n^');
        testInsertPadded('text start; one empty line; insertion point; two empty lines',
          '\n^\n\n',     'a\n', '\na\n\n^\n');
        testInsertPadded('text start; two empty lines; insertion point; one empty line',
          '\n\n^\n',     'a\n', '\n\na\n\n^');
        testInsertPadded('text start; two empty lines; insertion point; two empty lines',
          '\n\n^\n\n',   'a\n', '\n\na\n\n^\n');
      });
    });
  });

  group('length validation', () {
    final channel = eg.stream();

    /// String where there are [n] Unicode code points,
    /// >[n] UTF-16 code units, and <[n] "characters" a.k.a. grapheme clusters.
    String makeStringWithCodePoints(int n) {
      assert(n >= 5);
      const graphemeCluster = '👨‍👩‍👦';
      assert(graphemeCluster.runes.length == 5);
      assert(graphemeCluster.length == 8);
      assert(graphemeCluster.characters.length == 1);

      final result =
        graphemeCluster * (n ~/ 5)
        + 'a' * (n % 5);
      assert(result.runes.length == n);

      return result;
    }

    group('content', () {
      Future<void> prepareWithContent(WidgetTester tester, String content) async {
        TypingNotifier.debugEnable = false;
        addTearDown(TypingNotifier.debugReset);

        final narrow = ChannelNarrow(channel.streamId);
        await prepareComposeBox(tester, narrow: narrow, streams: [channel]);
        await enterTopic(tester, narrow: narrow, topic: 'some topic');
        await enterContent(tester, content);
      }

      Future<void> checkErrorResponse(WidgetTester tester) async {
        await tester.tap(find.byWidget(checkErrorDialog(tester,
          expectedTitle: 'Message not sent',
          expectedMessage: 'Message length shouldn\'t be greater than 10000 characters.')));
      }

      testWidgets('too-long content is rejected', (tester) async {
        await prepareWithContent(tester,
          makeStringWithCodePoints(kMaxMessageLengthCodePoints + 1));
        await tapSendButton(tester);
        await checkErrorResponse(tester);
      });

      testWidgets('max-length content not rejected', (tester) async {
        await prepareWithContent(tester,
          makeStringWithCodePoints(kMaxMessageLengthCodePoints));
        await tapSendButton(tester);
        checkNoErrorDialog(tester);
      });

      testWidgets('code points not counted unnecessarily', (tester) async {
        await prepareWithContent(tester, 'a' * kMaxMessageLengthCodePoints);
        check(controller!.content.debugLengthUnicodeCodePointsIfLong).isNull();
      });
    });

    group('topic', () {
      Future<void> prepareWithTopic(WidgetTester tester, String topic) async {
        TypingNotifier.debugEnable = false;
        addTearDown(TypingNotifier.debugReset);

        final narrow = ChannelNarrow(channel.streamId);
        await prepareComposeBox(tester, narrow: narrow, streams: [channel]);
        await enterTopic(tester, narrow: narrow, topic: topic);
        await enterContent(tester, 'some content');
      }

      Future<void> checkErrorResponse(WidgetTester tester) async {
        await tester.tap(find.byWidget(checkErrorDialog(tester,
          expectedTitle: 'Message not sent',
          expectedMessage: 'Topic length shouldn\'t be greater than 60 characters.')));
      }

      testWidgets('too-long topic is rejected', (tester) async {
        await prepareWithTopic(tester,
          makeStringWithCodePoints(kMaxTopicLengthCodePoints + 1));
        await tapSendButton(tester);
        await checkErrorResponse(tester);
      });

      testWidgets('max-length topic not rejected', (tester) async {
        await prepareWithTopic(tester,
          makeStringWithCodePoints(kMaxTopicLengthCodePoints));
        await tapSendButton(tester);
        checkNoErrorDialog(tester);
      });

      testWidgets('code points not counted unnecessarily', (tester) async {
        await prepareWithTopic(tester, 'a' * kMaxTopicLengthCodePoints);
        check((controller as StreamComposeBoxController)
          .topic.debugLengthUnicodeCodePointsIfLong).isNull();
      });
    });
  });

  group('ComposeBox hintText', () {
    final channel = eg.stream();

    Future<void> prepare(WidgetTester tester, {
      required Narrow narrow,
      bool? mandatoryTopics,
      int? zulipFeatureLevel,
    }) async {
      await prepareComposeBox(tester,
        narrow: narrow,
        otherUsers: [eg.otherUser, eg.thirdUser],
        streams: [channel],
        mandatoryTopics: mandatoryTopics,
        zulipFeatureLevel: zulipFeatureLevel);
    }

    /// This checks the input's configured hint text without regard to whether
    /// it's currently visible, as it won't be if the user has entered some text.
    ///
    /// If `topicHintText` is `null`, check that the topic input is not present.
    void checkComposeBoxHintTexts(WidgetTester tester, {
      String? topicHintText,
      required String contentHintText,
    }) {
      if (topicHintText != null) {
        check(tester.widget<TextField>(topicInputFinder))
          .decoration.isNotNull().hintText.equals(topicHintText);
      } else {
        check(topicInputFinder).findsNothing();
      }
      check(tester.widget<TextField>(contentInputFinder))
        .decoration.isNotNull().hintText.equals(contentHintText);
    }

    group('to ChannelNarrow, topics not mandatory', () {
      final narrow = ChannelNarrow(channel.streamId);

      testWidgets('with empty topic, topic input has focus', (tester) async {
        await prepare(tester, narrow: narrow, mandatoryTopics: false);
        await enterTopic(tester, narrow: narrow, topic: '');
        await tester.pump();
        checkComposeBoxHintTexts(tester,
          topicHintText: 'Topic',
          contentHintText: 'Message #${channel.name}');
      });

      testWidgets('legacy: with empty topic, topic input has focus', (tester) async {
        await prepare(tester, narrow: narrow, mandatoryTopics: false,
          zulipFeatureLevel: 333); // TODO(server-10)
        await enterTopic(tester, narrow: narrow, topic: '');
        await tester.pump();
        checkComposeBoxHintTexts(tester,
          topicHintText: 'Topic',
          contentHintText: 'Message #${channel.name}');
      });

      testWidgets('with non-empty but vacuous topic, topic input has focus', (tester) async {
        await prepare(tester, narrow: narrow, mandatoryTopics: false);
        await enterTopic(tester, narrow: narrow,
          topic: eg.defaultRealmEmptyTopicDisplayName);
        await tester.pump();
        checkComposeBoxHintTexts(tester,
          topicHintText: 'Topic',
          contentHintText: 'Message #${channel.name}');
      });

      testWidgets('with empty topic, content input has focus', (tester) async {
        await prepare(tester, narrow: narrow, mandatoryTopics: false);
        await enterContent(tester, '');
        await tester.pump();
        checkComposeBoxHintTexts(tester,
          topicHintText: 'Topic',
          contentHintText: 'Message #${channel.name} > '
                           '${eg.defaultRealmEmptyTopicDisplayName}');
      }, skip: true); // null topic names soon to be enabled

      testWidgets('legacy: with empty topic, content input has focus', (tester) async {
        await prepare(tester, narrow: narrow, mandatoryTopics: false,
          zulipFeatureLevel: 333);
        await enterContent(tester, '');
        await tester.pump();
        checkComposeBoxHintTexts(tester,
          topicHintText: 'Topic',
          contentHintText: 'Message #${channel.name} > (no topic)');
      });

      testWidgets('with non-empty topic', (tester) async {
        await prepare(tester, narrow: narrow, mandatoryTopics: false);
        await enterTopic(tester, narrow: narrow, topic: 'new topic');
        await tester.pump();
        checkComposeBoxHintTexts(tester,
          topicHintText: 'Topic',
          contentHintText: 'Message #${channel.name} > new topic');
      });
    });

    group('to ChannelNarrow, mandatory topics', () {
      final narrow = ChannelNarrow(channel.streamId);

      testWidgets('with empty topic', (tester) async {
        await prepare(tester, narrow: narrow, mandatoryTopics: true);
        checkComposeBoxHintTexts(tester,
          topicHintText: 'Topic',
          contentHintText: 'Message #${channel.name}');
      });

      testWidgets('legacy: with empty topic', (tester) async {
        await prepare(tester, narrow: narrow, mandatoryTopics: true,
          zulipFeatureLevel: 333); // TODO(server-10)
        checkComposeBoxHintTexts(tester,
          topicHintText: 'Topic',
          contentHintText: 'Message #${channel.name}');
      });

      group('with non-empty but vacuous topics', () {
        testWidgets('realm_empty_topic_display_name', (tester) async {
          await prepare(tester, narrow: narrow, mandatoryTopics: true);
          await enterTopic(tester, narrow: narrow,
            topic: eg.defaultRealmEmptyTopicDisplayName);
          await tester.pump();
          checkComposeBoxHintTexts(tester,
            topicHintText: 'Topic',
            contentHintText: 'Message #${channel.name}');
        });

        testWidgets('"(no topic)"', (tester) async {
          await prepare(tester, narrow: narrow, mandatoryTopics: true);
          await enterTopic(tester, narrow: narrow,
            topic: '(no topic)');
          await tester.pump();
          checkComposeBoxHintTexts(tester,
            topicHintText: 'Topic',
            contentHintText: 'Message #${channel.name}');
        });
      });

      testWidgets('with non-empty topic', (tester) async {
        await prepare(tester, narrow: narrow, mandatoryTopics: true);
        await enterTopic(tester, narrow: narrow, topic: 'new topic');
        await tester.pump();
        checkComposeBoxHintTexts(tester,
          topicHintText: 'Topic',
          contentHintText: 'Message #${channel.name} > new topic');
      });
    });

    group('to TopicNarrow', () {
      testWidgets('with non-empty topic', (tester) async {
        await prepare(tester,
          narrow: TopicNarrow(channel.streamId, TopicName('topic')));
        checkComposeBoxHintTexts(tester,
          contentHintText: 'Message #${channel.name} > topic');
      });

      testWidgets('with empty topic', (tester) async {
        await prepare(tester,
          narrow: TopicNarrow(channel.streamId, TopicName('')));
        checkComposeBoxHintTexts(tester, contentHintText:
          'Message #${channel.name} > ${eg.defaultRealmEmptyTopicDisplayName}');
      }, skip: true); // null topic names soon to be enabled
    });

    testWidgets('to DmNarrow with self', (tester) async {
      await prepare(tester, narrow: DmNarrow.withUser(
        eg.selfUser.userId, selfUserId: eg.selfUser.userId));
      checkComposeBoxHintTexts(tester,
        contentHintText: 'Jot down something');
    });

    testWidgets('to 1:1 DmNarrow', (tester) async {
      await prepare(tester, narrow: DmNarrow.withUser(
        eg.otherUser.userId, selfUserId: eg.selfUser.userId));
      checkComposeBoxHintTexts(tester,
        contentHintText: 'Message @${eg.otherUser.fullName}');
    });

    testWidgets('to group DmNarrow', (tester) async {
      await prepare(tester, narrow: DmNarrow.withOtherUsers(
        [eg.otherUser.userId, eg.thirdUser.userId],
        selfUserId: eg.selfUser.userId));
      checkComposeBoxHintTexts(tester,
        contentHintText: 'Message group');
    });
  });

  group('ComposeBox textCapitalization', () {
    void checkComposeBoxTextFields(WidgetTester tester, {
      required bool expectTopicTextField,
    }) {
      if (expectTopicTextField) {
        final topicController = (controller as StreamComposeBoxController).topic;
        final topicTextField = tester.widgetList<TextField>(find.byWidgetPredicate(
          (widget) => widget is TextField && widget.controller == topicController
        )).singleOrNull;
        check(topicTextField).isNotNull()
          .textCapitalization.equals(TextCapitalization.none);
      } else {
        check(controller).isA<FixedDestinationComposeBoxController>();
        check(find.byType(TextField)).findsOne(); // just content input, no topic
      }

      final contentTextField = tester.widget<TextField>(find.byWidgetPredicate(
        (widget) => widget is TextField
          && widget.controller == controller!.content));
      check(contentTextField)
        .textCapitalization.equals(TextCapitalization.sentences);
    }

    testWidgets('_StreamComposeBox', (tester) async {
      final channel = eg.stream();
      await prepareComposeBox(tester,
        narrow: ChannelNarrow(channel.streamId), streams: [channel]);
      checkComposeBoxTextFields(tester, expectTopicTextField: true);
    });

    testWidgets('_FixedDestinationComposeBox', (tester) async {
      final channel = eg.stream();
      await prepareComposeBox(tester,
        narrow: eg.topicNarrow(channel.streamId, 'topic'), streams: [channel]);
      checkComposeBoxTextFields(tester, expectTopicTextField: false);
    });
  });

  group('ComposeBox typing notices', () {
    final channel = eg.stream();
    final narrow = eg.topicNarrow(channel.streamId, 'some topic');

    void checkTypingRequest(TypingOp op, SendableNarrow narrow) =>
      checkSetTypingStatusRequests(connection.takeRequests(), [(op, narrow)]);

    Future<void> checkStartTyping(WidgetTester tester, SendableNarrow narrow) async {
      connection.prepare(json: {});
      await enterContent(tester, 'hello world');
      checkTypingRequest(TypingOp.start, narrow);
    }

    testWidgets('smoke TopicNarrow', (tester) async {
      await prepareComposeBox(tester, narrow: narrow, streams: [channel]);

      await checkStartTyping(tester, narrow);

      connection.prepare(json: {});
      await tester.pump(store.typingNotifier.typingStoppedWaitPeriod);
      checkTypingRequest(TypingOp.stop, narrow);
    });

    testWidgets('smoke DmNarrow', (tester) async {
      final narrow = DmNarrow.withUsers(
        [eg.otherUser.userId], selfUserId: eg.selfUser.userId);
      await prepareComposeBox(tester, narrow: narrow);

      await checkStartTyping(tester, narrow);

      connection.prepare(json: {});
      await tester.pump(store.typingNotifier.typingStoppedWaitPeriod);
      checkTypingRequest(TypingOp.stop, narrow);
    });

    testWidgets('smoke ChannelNarrow', (tester) async {
      final narrow = ChannelNarrow(channel.streamId);
      final destinationNarrow = eg.topicNarrow(narrow.streamId, 'test topic');
      await prepareComposeBox(tester, narrow: narrow, streams: [channel]);
      await enterTopic(tester, narrow: narrow, topic: 'test topic');

      await checkStartTyping(tester, destinationNarrow);

      connection.prepare(json: {});
      await tester.pump(store.typingNotifier.typingStoppedWaitPeriod);
      checkTypingRequest(TypingOp.stop, destinationNarrow);
    });

    testWidgets('clearing text sends a "typing stopped" notice', (tester) async {
      await prepareComposeBox(tester, narrow: narrow, streams: [channel]);

      await checkStartTyping(tester, narrow);

      connection.prepare(json: {});
      await enterContent(tester, '');
      checkTypingRequest(TypingOp.stop, narrow);
    });

    testWidgets('hitting send button sends a "typing stopped" notice', (tester) async {
      await prepareComposeBox(tester, narrow: narrow, streams: [channel]);

      await checkStartTyping(tester, narrow);

      connection.prepare(json: {});
      connection.prepare(json: SendMessageResult(id: 123).toJson());
      await tester.tap(find.byIcon(ZulipIcons.send));
      await tester.pump(Duration.zero);
      final requests = connection.takeRequests();
      checkSetTypingStatusRequests([requests.first], [(TypingOp.stop, narrow)]);
      check(requests).length.equals(2);
    });

    Future<void> prepareComposeBoxWithNavigation(WidgetTester tester) async {
      addTearDown(testBinding.reset);
      final selfUser = eg.selfUser;
      final selfAccount = eg.account(user: selfUser);
      await testBinding.globalStore.add(selfAccount, eg.initialSnapshot());

      store = await testBinding.globalStore.perAccount(selfAccount.id);
      await store.addUser(selfUser);
      await store.addStream(channel);
      connection = store.connection as FakeApiConnection;

      await tester.pumpWidget(const ZulipApp());
      await tester.pump();
      final navigator = await ZulipApp.navigator;
      unawaited(navigator.push(MaterialAccountWidgetRoute(
        accountId: selfAccount.id, page: ComposeBox(narrow: narrow))));
      await tester.pumpAndSettle();
    }

    testWidgets('navigating away sends a "typing stopped" notice', (tester) async {
      await prepareComposeBoxWithNavigation(tester);

      await checkStartTyping(tester, narrow);

      connection.prepare(json: {});
      (await ZulipApp.navigator).pop();
      await tester.pump(Duration.zero);
      checkTypingRequest(TypingOp.stop, narrow);
    });

    testWidgets('for content input, unfocusing sends a "typing stopped" notice', (tester) async {
      final narrow = ChannelNarrow(channel.streamId);
      final destinationNarrow = eg.topicNarrow(narrow.streamId, 'test topic');
      await prepareComposeBox(tester, narrow: narrow, streams: [channel]);
      await enterTopic(tester, narrow: narrow, topic: 'test topic');

      await checkStartTyping(tester, destinationNarrow);

      connection.prepare(json: {});
      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pump(Duration.zero);
      checkTypingRequest(TypingOp.stop, destinationNarrow);
    });

    testWidgets('selection change sends a "typing started" notice', (tester) async {
      await prepareComposeBox(tester, narrow: narrow, streams: [channel]);

      await checkStartTyping(tester, narrow);

      connection.prepare(json: {});
      await tester.pump(store.typingNotifier.typingStoppedWaitPeriod);
      checkTypingRequest(TypingOp.stop, narrow);

      connection.prepare(json: {});
      controller!.content.selection =
        const TextSelection(baseOffset: 0, extentOffset: 2);
      checkTypingRequest(TypingOp.start, narrow);

      // Ensures that a "typing stopped" notice is sent when the test ends.
      connection.prepare(json: {});
      await tester.pump(store.typingNotifier.typingStoppedWaitPeriod);
      checkTypingRequest(TypingOp.stop, narrow);
    });

    testWidgets('unfocusing app sends a "typing stopped" notice', (tester) async {
      await prepareComposeBox(tester, narrow: narrow, streams: [channel]);

      await checkStartTyping(tester, narrow);

      connection.prepare(json: {});
      // While this state lives on [ServicesBinding], testWidgets resets it
      // for us when the test ends so we don't have to:
      //   https://github.com/flutter/flutter/blob/c78c166e3ecf963ca29ed503e710fd3c71eda5c9/packages/flutter_test/lib/src/binding.dart#L1189
      // On iOS and Android, a transition to [hidden] is synthesized before
      // transitioning into [paused].
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.hidden);
      await tester.pump(Duration.zero);
      checkTypingRequest(TypingOp.stop, narrow);

      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused);
      await tester.pump(Duration.zero);
      check(connection.lastRequest).isNull();
    });
  });

  group('message-send request response', () {
    Future<void> setupAndTapSend(WidgetTester tester, {
      required void Function(int messageId) prepareResponse,
    }) async {
      TypingNotifier.debugEnable = false;
      addTearDown(TypingNotifier.debugReset);

      final zulipLocalizations = GlobalLocalizations.zulipLocalizations;
      await prepareComposeBox(tester, narrow: eg.topicNarrow(123, 'some topic'),
        streams: [eg.stream(streamId: 123)]);

      await enterContent(tester, 'hello world');

      prepareResponse(456);
      await tester.tap(find.byTooltip(zulipLocalizations.composeBoxSendTooltip));
      await tester.pump(Duration.zero);

      check(connection.lastRequest).isA<http.Request>()
        ..method.equals('POST')
        ..url.path.equals('/api/v1/messages')
        ..bodyFields.deepEquals({
            'type': 'stream',
            'to': '123',
            'topic': 'some topic',
            'content': 'hello world',
            'read_by_sender': 'true',
          });
    }

    testWidgets('success', (tester) async {
      await setupAndTapSend(tester, prepareResponse: (int messageId) {
        connection.prepare(json: SendMessageResult(id: messageId).toJson());
      });
      checkNoErrorDialog(tester);
    });

    testWidgets('ZulipApiException', (tester) async {
      await setupAndTapSend(tester, prepareResponse: (message) {
        connection.prepare(apiException: eg.apiBadRequest(
          message: 'You do not have permission to initiate direct message conversations.'));
      });
      final zulipLocalizations = GlobalLocalizations.zulipLocalizations;
      await tester.tap(find.byWidget(checkErrorDialog(tester,
        expectedTitle: zulipLocalizations.errorMessageNotSent,
        expectedMessage: zulipLocalizations.errorServerMessage(
          'You do not have permission to initiate direct message conversations.'),
      )));
    });
  });

  group('sending to empty topic', () {
    late ZulipStream channel;

    Future<void> setupAndTapSend(WidgetTester tester, {
      required String topicInputText,
      required bool mandatoryTopics,
      int? zulipFeatureLevel,
    }) async {
      TypingNotifier.debugEnable = false;
      addTearDown(TypingNotifier.debugReset);

      channel = eg.stream();
      final narrow = ChannelNarrow(channel.streamId);
      await prepareComposeBox(tester,
        narrow: narrow, streams: [channel],
        mandatoryTopics: mandatoryTopics,
        zulipFeatureLevel: zulipFeatureLevel);

      await enterTopic(tester, narrow: narrow, topic: topicInputText);
      await tester.enterText(contentInputFinder, 'test content');
      await tester.tap(find.byIcon(ZulipIcons.send));
      await tester.pump();
    }

    void checkMessageNotSent(WidgetTester tester) {
      check(connection.takeRequests()).isEmpty();
      checkErrorDialog(tester,
        expectedTitle: 'Message not sent',
        expectedMessage: 'Topics are required in this organization.');
    }

    testWidgets('empty topic -> ""', (tester) async {
      await setupAndTapSend(tester,
        topicInputText: '',
        mandatoryTopics: false);
      check(connection.lastRequest).isA<http.Request>()
        ..method.equals('POST')
        ..url.path.equals('/api/v1/messages')
        ..bodyFields['topic'].equals('');
    });

    testWidgets('legacy: empty topic -> "(no topic)"', (tester) async {
      await setupAndTapSend(tester,
        topicInputText: '',
        mandatoryTopics: false,
        zulipFeatureLevel: 333);
      check(connection.lastRequest).isA<http.Request>()
        ..method.equals('POST')
        ..url.path.equals('/api/v1/messages')
        ..bodyFields['topic'].equals('(no topic)');
    });

    testWidgets('if topics are mandatory, reject empty topic', (tester) async {
      await setupAndTapSend(tester,
        topicInputText: '',
        mandatoryTopics: true);
      checkMessageNotSent(tester);
    });

    testWidgets('if topics are mandatory, reject `realmEmptyTopicDisplayName`', (tester) async {
      await setupAndTapSend(tester,
        topicInputText: eg.defaultRealmEmptyTopicDisplayName,
        mandatoryTopics: true);
      checkMessageNotSent(tester);
    });

    testWidgets('if topics are mandatory, reject "(no topic)"', (tester) async {
      await setupAndTapSend(tester,
        topicInputText: '(no topic)',
        mandatoryTopics: true);
      checkMessageNotSent(tester);
    });
  });

  group('uploads', () {
    void checkAppearsLoading(WidgetTester tester, bool expected) {
      final sendButtonElement = tester.element(find.ancestor(
        of: find.byIcon(ZulipIcons.send),
        matching: find.byType(IconButton)));
      final sendButtonWidget = sendButtonElement.widget as IconButton;
      final designVariables = DesignVariables.of(sendButtonElement);
      final expectedIconColor = expected
        ? designVariables.icon.withFadedAlpha(0.5)
        : designVariables.icon;
      check(sendButtonWidget.icon)
        .isA<Icon>().color.isNotNull().isSameColorAs(expectedIconColor);
    }

    group('attach from media library', () {
      testWidgets('success', (tester) async {
        TypingNotifier.debugEnable = false;
        addTearDown(TypingNotifier.debugReset);

        final channel = eg.stream();
        final narrow = ChannelNarrow(channel.streamId);
        await prepareComposeBox(tester, narrow: narrow, streams: [channel]);

        // (When we check that the send button looks disabled, it should be because
        // the file is uploading, not a pre-existing reason.)
        await enterTopic(tester, narrow: narrow, topic: 'some topic');
        controller!.content.value = const TextEditingValue(text: 'see image: ');
        await tester.pump();
        checkAppearsLoading(tester, false);

        testBinding.pickFilesResult = FilePickerResult([PlatformFile(
          readStream: Stream.fromIterable(['asdf'.codeUnits]),
          // TODO test inference of MIME type from initial bytes, when
          //   it can't be inferred from path
          path: '/private/var/mobile/Containers/Data/Application/foo/tmp/image.jpg',
          name: 'image.jpg',
          size: 12345,
        )]);
        connection.prepare(delay: const Duration(seconds: 1), json:
          UploadFileResult(uri: '/user_uploads/1/4e/m2A3MSqFnWRLUf9SaPzQ0Up_/image.jpg').toJson());

        await tester.tap(find.byIcon(ZulipIcons.image));
        await tester.pump();
        final call = testBinding.takePickFilesCalls().single;
        check(call.allowMultiple).equals(true);
        check(call.type).equals(FileType.media);

        checkNoErrorDialog(tester);

        check(controller!.content.text)
          .equals('see image: [Uploading image.jpg…]()\n\n');
        // (the request is checked more thoroughly in API tests)
        check(connection.lastRequest!).isA<http.MultipartRequest>()
          ..method.equals('POST')
          ..files.single.which((it) => it
            ..field.equals('file')
            ..length.equals(12345)
            ..filename.equals('image.jpg')
            ..contentType.asString.equals('image/jpeg')
            ..has<Future<List<int>>>((f) => f.finalize().toBytes(), 'contents')
              .completes((it) => it.deepEquals(['asdf'.codeUnits].expand((l) => l)))
          );
        checkAppearsLoading(tester, true);

        await tester.pump(const Duration(seconds: 1));
        check(controller!.content.text)
          .equals('see image: [image.jpg](/user_uploads/1/4e/m2A3MSqFnWRLUf9SaPzQ0Up_/image.jpg)\n\n');
        checkAppearsLoading(tester, false);
      });

      // TODO test what happens when selecting/uploading fails
    });

    group('attach from camera', () {
      testWidgets('success', (tester) async {
        TypingNotifier.debugEnable = false;
        addTearDown(TypingNotifier.debugReset);

        final channel = eg.stream();
        final narrow = ChannelNarrow(channel.streamId);
        await prepareComposeBox(tester, narrow: narrow, streams: [channel]);

        // (When we check that the send button looks disabled, it should be because
        // the file is uploading, not a pre-existing reason.)
        await enterTopic(tester, narrow: narrow, topic: 'some topic');
        controller!.content.value = const TextEditingValue(text: 'see image: ');
        await tester.pump();
        checkAppearsLoading(tester, false);

        testBinding.pickImageResult = XFile.fromData(
          // TODO test inference of MIME type when it's missing here
          mimeType: 'image/jpeg',
          utf8.encode('asdf'),
          name: 'image.jpg',
          length: 12345,
          path: '/private/var/mobile/Containers/Data/Application/foo/tmp/image.jpg',
        );
        connection.prepare(delay: const Duration(seconds: 1), json:
          UploadFileResult(uri: '/user_uploads/1/4e/m2A3MSqFnWRLUf9SaPzQ0Up_/image.jpg').toJson());

        await tester.tap(find.byIcon(ZulipIcons.camera));
        await tester.pump();
        final call = testBinding.takePickImageCalls().single;
        check(call.source).equals(ImageSource.camera);
        check(call.requestFullMetadata).equals(false);

        checkNoErrorDialog(tester);

        check(controller!.content.text)
          .equals('see image: [Uploading image.jpg…]()\n\n');
        // (the request is checked more thoroughly in API tests)
        check(connection.lastRequest!).isA<http.MultipartRequest>()
          ..method.equals('POST')
          ..files.single.which((it) => it
            ..field.equals('file')
            ..length.equals(12345)
            ..filename.equals('image.jpg')
            ..contentType.asString.equals('image/jpeg')
            ..has<Future<List<int>>>((f) => f.finalize().toBytes(), 'contents')
              .completes((it) => it.deepEquals(['asdf'.codeUnits].expand((l) => l)))
          );
        checkAppearsLoading(tester, true);

        await tester.pump(const Duration(seconds: 1));
        check(controller!.content.text)
          .equals('see image: [image.jpg](/user_uploads/1/4e/m2A3MSqFnWRLUf9SaPzQ0Up_/image.jpg)\n\n');
        checkAppearsLoading(tester, false);
      });

      // TODO test what happens when capturing/uploading fails
    },
    // This test fails on Windows because [XFile.name] splits on
    // [Platform.pathSeparator], corresponding to the actual host platform
    // the test is running on, instead of the path separator for the
    // target platform the test is simulating.
    // TODO(upstream): unskip after fix to https://github.com/flutter/flutter/issues/161073
    skip: Platform.isWindows);
  });

  group('error banner', () {
    final zulipLocalizations = GlobalLocalizations.zulipLocalizations;

    Finder inputFieldFinder() => find.descendant(
      of: find.byType(ComposeBox),
      matching: find.byType(TextField));

    Finder attachButtonFinder(IconData icon) => find.descendant(
      of: find.byType(ComposeBox),
      matching: find.widgetWithIcon(IconButton, icon));

    void checkComposeBoxParts({required bool areShown}) {
      final inputFieldCount = inputFieldFinder().evaluate().length;
      areShown ? check(inputFieldCount).isGreaterThan(0) : check(inputFieldCount).equals(0);
      check(attachButtonFinder(ZulipIcons.attach_file).evaluate().length).equals(areShown ? 1 : 0);
      check(attachButtonFinder(ZulipIcons.image).evaluate().length).equals(areShown ? 1 : 0);
      check(attachButtonFinder(ZulipIcons.camera).evaluate().length).equals(areShown ? 1 : 0);
    }

    void checkBannerWithLabel(String label, {required bool isShown}) {
      check(find.text(label).evaluate().length).equals(isShown ? 1 : 0);
    }

    void checkComposeBoxIsShown(bool isShown, {required String bannerLabel}) {
      checkComposeBoxParts(areShown: isShown);
      checkBannerWithLabel(bannerLabel, isShown: !isShown);
    }

    group('in DMs with deactivated users', () {
      void checkComposeBox({required bool isShown}) => checkComposeBoxIsShown(isShown,
        bannerLabel: zulipLocalizations.errorBannerDeactivatedDmLabel);

      Future<void> changeUserStatus(WidgetTester tester,
          {required User user, required bool isActive}) async {
        await store.handleEvent(RealmUserUpdateEvent(id: 1,
          userId: user.userId, isActive: isActive));
        await tester.pump();
      }

      DmNarrow dmNarrowWith(User otherUser) => DmNarrow.withUser(otherUser.userId,
        selfUserId: eg.selfUser.userId);

      DmNarrow groupDmNarrowWith(List<User> otherUsers) => DmNarrow.withOtherUsers(
        otherUsers.map((u) => u.userId), selfUserId: eg.selfUser.userId);

      group('1:1 DMs', () {
        testWidgets('compose box replaced with a banner', (tester) async {
          final deactivatedUser = eg.user(isActive: false);
          await prepareComposeBox(tester, narrow: dmNarrowWith(deactivatedUser),
            otherUsers: [deactivatedUser]);
          checkComposeBox(isShown: false);
        });

        testWidgets('active user becomes deactivated -> '
            'compose box is replaced with a banner', (tester) async {
          final activeUser = eg.user(isActive: true);
          await prepareComposeBox(tester, narrow: dmNarrowWith(activeUser),
            otherUsers: [activeUser]);
          checkComposeBox(isShown: true);

          await changeUserStatus(tester, user: activeUser, isActive: false);
          checkComposeBox(isShown: false);
        });

        testWidgets('deactivated user becomes active -> '
            'banner is replaced with the compose box', (tester) async {
          final deactivatedUser = eg.user(isActive: false);
          await prepareComposeBox(tester, narrow: dmNarrowWith(deactivatedUser),
            otherUsers: [deactivatedUser]);
          checkComposeBox(isShown: false);

          await changeUserStatus(tester, user: deactivatedUser, isActive: true);
          checkComposeBox(isShown: true);
        });
      });

      group('group DMs', () {
        testWidgets('compose box replaced with a banner', (tester) async {
          final deactivatedUsers = [eg.user(isActive: false), eg.user(isActive: false)];
          await prepareComposeBox(tester, narrow: groupDmNarrowWith(deactivatedUsers),
            otherUsers: deactivatedUsers);
          checkComposeBox(isShown: false);
        });

        testWidgets('at least one user becomes deactivated -> '
            'compose box is replaced with a banner', (tester) async {
          final activeUsers = [eg.user(isActive: true), eg.user(isActive: true)];
          await prepareComposeBox(tester, narrow: groupDmNarrowWith(activeUsers),
            otherUsers: activeUsers);
          checkComposeBox(isShown: true);

          await changeUserStatus(tester, user: activeUsers[0], isActive: false);
          checkComposeBox(isShown: false);
        });

        testWidgets('all deactivated users become active -> '
            'banner is replaced with the compose box', (tester) async {
          final deactivatedUsers = [eg.user(isActive: false), eg.user(isActive: false)];
          await prepareComposeBox(tester, narrow: groupDmNarrowWith(deactivatedUsers),
            otherUsers: deactivatedUsers);
          checkComposeBox(isShown: false);

          await changeUserStatus(tester, user: deactivatedUsers[0], isActive: true);
          checkComposeBox(isShown: false);

          await changeUserStatus(tester, user: deactivatedUsers[1], isActive: true);
          checkComposeBox(isShown: true);
        });
      });
    });

    group('in channel/topic narrow according to channel post policy', () {
      void checkComposeBox({required bool isShown}) => checkComposeBoxIsShown(isShown,
        bannerLabel: zulipLocalizations.errorBannerCannotPostInChannelLabel);

      final narrowTestCases = [
        ('channel', const ChannelNarrow(1)),
        ('topic',   eg.topicNarrow(1, 'topic')),
      ];

      for (final (String narrowType, Narrow narrow) in narrowTestCases) {
        testWidgets('compose box is shown in $narrowType narrow', (tester) async {
          await prepareComposeBox(tester,
            narrow: narrow,
            selfUser: eg.user(role: UserRole.administrator),
            streams: [eg.stream(streamId: 1,
              channelPostPolicy: ChannelPostPolicy.moderators)]);
          checkComposeBox(isShown: true);
        });

        testWidgets('error banner is shown in $narrowType narrow', (tester) async {
          await prepareComposeBox(tester,
            narrow: narrow,
            selfUser: eg.user(role: UserRole.moderator),
            streams: [eg.stream(streamId: 1,
              channelPostPolicy: ChannelPostPolicy.administrators)]);
          checkComposeBox(isShown: false);
        });
      }

      testWidgets('user loses privilege -> compose box is replaced with the banner', (tester) async {
        final selfUser = eg.user(role: UserRole.administrator);
        await prepareComposeBox(tester,
          narrow: const ChannelNarrow(1),
          selfUser: selfUser,
          streams: [eg.stream(streamId: 1,
            channelPostPolicy: ChannelPostPolicy.administrators)]);
        checkComposeBox(isShown: true);

        await store.handleEvent(RealmUserUpdateEvent(id: 1,
          userId: selfUser.userId, role: UserRole.moderator));
        await tester.pump();
        checkComposeBox(isShown: false);
      });

      testWidgets('user gains privilege -> banner is replaced with the compose box', (tester) async {
        final selfUser = eg.user(role: UserRole.guest);
        await prepareComposeBox(tester,
          narrow: const ChannelNarrow(1),
          selfUser: selfUser,
          streams: [eg.stream(streamId: 1,
            channelPostPolicy: ChannelPostPolicy.moderators)]);
        checkComposeBox(isShown: false);

        await store.handleEvent(RealmUserUpdateEvent(id: 1,
          userId: selfUser.userId, role: UserRole.administrator));
        await tester.pump();
        checkComposeBox(isShown: true);
      });

      testWidgets('channel policy becomes stricter -> compose box is replaced with the banner', (tester) async {
        final selfUser = eg.user(role: UserRole.guest);
        final channel = eg.stream(streamId: 1,
          channelPostPolicy: ChannelPostPolicy.any);

        await prepareComposeBox(tester,
          narrow: const ChannelNarrow(1),
          selfUser: selfUser,
          streams: [channel]);
        checkComposeBox(isShown: true);

        await store.handleEvent(eg.channelUpdateEvent(channel,
          property: ChannelPropertyName.channelPostPolicy,
          value: ChannelPostPolicy.fullMembers));
        await tester.pump();
        checkComposeBox(isShown: false);
      });

      testWidgets('channel policy becomes less strict -> banner is replaced with the compose box', (tester) async {
        final selfUser = eg.user(role: UserRole.moderator);
        final channel = eg.stream(streamId: 1,
          channelPostPolicy: ChannelPostPolicy.administrators);

        await prepareComposeBox(tester,
          narrow: const ChannelNarrow(1),
          selfUser: selfUser,
          streams: [channel]);
        checkComposeBox(isShown: false);

        await store.handleEvent(eg.channelUpdateEvent(channel,
          property: ChannelPropertyName.channelPostPolicy,
          value: ChannelPostPolicy.moderators));
        await tester.pump();
        checkComposeBox(isShown: true);
      });
    });
  });

  group('ComposeBox content input scaling', () {
    const verticalPadding = 8;
    final stream = eg.stream();
    final narrow = eg.topicNarrow(stream.streamId, 'foo');

    Future<void> checkContentInputMaxHeight(WidgetTester tester, {
      required double maxHeight,
      required int maxVisibleLines,
    }) async {
      TypingNotifier.debugEnable = false;
      addTearDown(TypingNotifier.debugReset);

      // Add one line at a time, until the content input reaches its max height.
      int numLines;
      double? height;
      for (numLines = 2; numLines <= 1000; numLines++) {
        final content = List.generate(numLines, (_) => 'foo').join('\n');
        await enterContent(tester, content);
        await tester.pump();
        final newHeight = tester.getRect(contentInputFinder).height;
        if (newHeight == height) {
          break;
        }
        height = newHeight;
      }
      check(height).isNotNull().isCloseTo(maxHeight, 0.5);
      // The last line added did not stretch the content input,
      // so only the lines before it are at least partially visible.
      check(numLines - 1).equals(maxVisibleLines);
    }

    testWidgets('normal text scale factor', (tester) async {
      await prepareComposeBox(tester, narrow: narrow, streams: [stream]);

      await checkContentInputMaxHeight(tester,
        maxHeight: verticalPadding + 170, maxVisibleLines: 8);
    });

    testWidgets('lower text scale factor', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 0.8;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await prepareComposeBox(tester, narrow: narrow, streams: [stream]);
      await checkContentInputMaxHeight(tester,
        maxHeight: verticalPadding + 170 * 0.8, maxVisibleLines: 8);
    });

    testWidgets('higher text scale factor', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await prepareComposeBox(tester, narrow: narrow, streams: [stream]);
      await checkContentInputMaxHeight(tester,
        maxHeight: verticalPadding + 170 * 1.5, maxVisibleLines: 8);
    });

    testWidgets('higher text scale factor exceeding threshold', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await prepareComposeBox(tester, narrow: narrow, streams: [stream]);
      await checkContentInputMaxHeight(tester,
        maxHeight: verticalPadding + 170 * 1.5, maxVisibleLines: 6);
    });
  });

  group('ComposeBoxState new-event-queue transition', () {
    testWidgets('content input not cleared when store changes', (tester) async {
      // Regression test for: https://github.com/zulip/zulip-flutter/issues/1470

      TypingNotifier.debugEnable = false;
      addTearDown(TypingNotifier.debugReset);

      final channel = eg.stream();
      await prepareComposeBox(tester,
        narrow: eg.topicNarrow(channel.streamId, 'topic'), streams: [channel]);

      await enterContent(tester, 'some content');
      checkContentInputValue(tester, 'some content');

      store.updateMachine!
        ..debugPauseLoop()
        ..poll()
        ..debugPrepareLoopError(
            eg.apiExceptionBadEventQueueId(queueId: store.queueId))
        ..debugAdvanceLoop();
      await tester.pump();

      final newStore = testBinding.globalStore.perAccountSync(store.accountId)!;
      check(newStore)
        // a new store has replaced the old one
        ..not((it) => it.identicalTo(store))
        // new store has the same boring data, in order to present a compose box
        // that allows composing, instead of a no-posting-permission banner
        ..accountId.equals(store.accountId)
        ..streams.containsKey(channel.streamId);

      checkContentInputValue(tester, 'some content');
    });
  });
}
