defmodule Sue.AI.InterjectionTest do
  use ExUnit.Case, async: true

  alias Bream.AssistantMessage
  alias Bream.TextBlock
  alias Sue.AI.Interjection
  alias Sue.Models.{Account, Attachment, Chat, Message, PlatformAccount, Response}

  test "candidate? accepts non-command text and media but rejects unsafe messages" do
    assert Interjection.candidate?(message(body: "Sue, what do you think?"))
    assert Interjection.candidate?(message(body: "", attachments: [image_attachment()]))

    refute Interjection.candidate?(
             message(command: "gpt", args: "hello", body: "!gpt hello", is_ignorable: false)
           )

    refute Interjection.candidate?(message(is_from_sue: true))
    refute Interjection.candidate?(message(account: %Account{id: "acct", is_ignored: true}))
    refute Interjection.candidate?(message(account: %Account{id: "acct", is_banned: true}))

    refute Interjection.candidate?(
             message(
               chat: %Chat{
                 id: "chat",
                 platform_id: {:debug, "chat"},
                 is_direct: false,
                 is_ignored: true
               }
             )
           )
  end

  test "decide sends the rolling ten-message window to Bream Chat" do
    recent_messages =
      for index <- 1..11 do
        %{name: "User#{index}", body: "message #{index}", is_from_sue: false, is_from_gpt: false}
      end

    chat_client = fn request ->
      assert request[:base_url] == "http://localhost:11434/v1"
      assert request[:model] == "LiquidAI/lfm2.5-1.2b-instruct:q5_k_m"
      assert request[:temperature] == 0
      assert request[:response_format] == %{"type" => "json_object"}

      [%{role: "system"}, %{role: "user", content: content}] = request[:messages]
      refute content =~ "1. User1: message 1"
      assert content =~ "User2: message 2"
      assert content =~ "10. User11: message 11"
      assert content =~ "The final line is the latest message"

      {:ok,
       assistant(%{
         should_interject: true,
         confidence: 0.91,
         reason: "addressed Sue"
       })}
    end

    assert {:ok, decision} =
             message(body: "Sue, answer this")
             |> Interjection.decide(
               chat_client: chat_client,
               recent_messages: recent_messages
             )

    assert decision.should_interject
    assert decision.confidence == 0.91
    assert decision.reason == "addressed Sue"
  end

  test "reply invokes Claude-backed Sue AI when the classifier says yes" do
    attachment = image_attachment()
    msg = message(body: "Sue, can you explain this?", attachments: [attachment])

    chat_client = fn _request ->
      {:ok, assistant(%{should_interject: true, confidence: 0.9})}
    end

    completion_fun = fn prompt, chat, account, attachments ->
      assert prompt == "#{msg.body} <media:image>"
      assert chat.id == msg.chat.id
      assert account.id == msg.account.id
      assert attachments == [attachment]
      "sure"
    end

    assert {:ok, %Response{body: "sure", is_from_gpt: true}} =
             Interjection.reply(msg,
               enabled: true,
               chat_client: chat_client,
               completion_fun: completion_fun,
               recent_messages: [%{name: "User", body: msg.body}],
               invoke_rate_limit: nil,
               gpt_rate_limit: nil
             )
  end

  test "reply bypasses the interjection throttle in direct chats" do
    chat = %Chat{
      id: "chat-direct-#{System.unique_integer([:positive])}",
      platform_id: {:debug, :direct},
      is_direct: true
    }

    account = %Account{id: "acct-direct-#{System.unique_integer([:positive])}"}
    msg = message(body: "Sue, answer this", chat: chat, account: account)

    chat_client = fn _request ->
      {:ok, assistant(%{should_interject: true, confidence: 1.0})}
    end

    completion_fun = fn _, _, _, _ -> "sure" end

    opts = [
      enabled: true,
      chat_client: chat_client,
      completion_fun: completion_fun,
      recent_messages: [%{name: "User", body: msg.body}],
      invoke_rate_limit: {:timer.minutes(5), 1},
      gpt_rate_limit: nil
    ]

    assert {:ok, %Response{body: "sure"}} = Interjection.reply(msg, opts)
    assert {:ok, %Response{body: "sure"}} = Interjection.reply(msg, opts)
  end

  test "reply throttles group interjections per chat" do
    chat = %Chat{
      id: "chat-group-#{System.unique_integer([:positive])}",
      platform_id: {:debug, :group},
      is_direct: false
    }

    account = %Account{id: "acct-group-#{System.unique_integer([:positive])}"}
    msg = message(body: "Sue, answer this", chat: chat, account: account)

    chat_client = fn _request ->
      {:ok, assistant(%{should_interject: true, confidence: 1.0})}
    end

    completion_fun = fn _, _, _, _ -> "sure" end

    opts = [
      enabled: true,
      chat_client: chat_client,
      completion_fun: completion_fun,
      recent_messages: [%{name: "User", body: msg.body}],
      invoke_rate_limit: {:timer.minutes(5), 1},
      gpt_rate_limit: nil
    ]

    assert {:ok, %Response{body: "sure"}} = Interjection.reply(msg, opts)
    assert :ignore = Interjection.reply(msg, opts)
  end

  test "reply stays silent when the classifier says no or confidence is low" do
    no_client = fn _request ->
      {:ok, assistant(%{should_interject: false, confidence: 1.0})}
    end

    low_confidence_client = fn _request ->
      {:ok, assistant(%{should_interject: true, confidence: 0.2})}
    end

    refute_called = fn _, _, _ -> flunk("Claude should not be called") end
    msg = message(body: "ordinary chat")

    assert :ignore =
             Interjection.reply(msg,
               enabled: true,
               chat_client: no_client,
               completion_fun: refute_called,
               recent_messages: [%{name: "User", body: msg.body}],
               invoke_rate_limit: nil,
               gpt_rate_limit: nil
             )

    assert :ignore =
             Interjection.reply(msg,
               enabled: true,
               chat_client: low_confidence_client,
               completion_fun: refute_called,
               recent_messages: [%{name: "User", body: msg.body}],
               invoke_rate_limit: nil,
               gpt_rate_limit: nil
             )
  end

  test "format_recent_body preserves text and marks media" do
    msg = message(body: "caption", attachments: [image_attachment()])

    assert Interjection.format_recent_body(msg) == "caption <media:image>"
  end

  test "recent message cache keeps ten messages" do
    chat_id = "chat:test:#{System.unique_integer([:positive])}"

    for index <- 1..12 do
      Sue.DB.RecentMessages.add(chat_id, %{name: "User", body: "message #{index}"})
    end

    messages = Sue.DB.RecentMessages.get(chat_id)

    assert length(messages) == 10
    assert %{body: "message 3"} = List.first(messages)
    assert %{body: "message 12"} = List.last(messages)
  end

  defp assistant(map) do
    %AssistantMessage{content: [%TextBlock{text: Jason.encode!(map)}]}
  end

  defp message(attrs) do
    unique = System.unique_integer([:positive])
    body = Keyword.get(attrs, :body, "hello")
    command = Keyword.get(attrs, :command, "")
    args = Keyword.get(attrs, :args, "")
    attachments = Keyword.get(attrs, :attachments, [])
    has_attachments = Keyword.get(attrs, :has_attachments, attachments != [])

    account = Keyword.get(attrs, :account, %Account{id: "acct-#{unique}"})

    chat =
      Keyword.get(attrs, :chat, %Chat{
        id: "chat-#{unique}",
        platform_id: {:debug, unique},
        is_direct: false
      })

    %Message{
      platform: :debug,
      id: "msg-#{unique}",
      paccount: %PlatformAccount{id: "pa-#{unique}", platform_id: {:debug, unique}},
      chat: chat,
      account: account,
      body: body,
      command: command,
      args: args,
      attachments: attachments,
      time: DateTime.utc_now(),
      is_from_sue: Keyword.get(attrs, :is_from_sue, false),
      is_ignorable: Keyword.get(attrs, :is_ignorable, true),
      has_attachments: has_attachments
    }
  end

  defp image_attachment do
    %Attachment{
      id: "image",
      filepath: "/tmp/image.jpg",
      mime_type: "image/jpeg",
      downloaded: true
    }
  end
end
