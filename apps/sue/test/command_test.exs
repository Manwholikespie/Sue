defmodule CommandTest do
  use ExUnit.Case

  alias Sue.Models.Message
  alias Sue.DB.Schema

  test "ping" do
    m = Message.from_debug("!ping")
    response = Sue.debug_blocking_process_message(m)
    assert response.body == "pong!"
  end

  test "random" do
    m = Message.from_debug("!flip")
    response = Sue.debug_blocking_process_message(m)
    assert response.body in ["heads", "tails"]
  end

  test "defn" do
    Schema.debug_clear_collections()

    m = Message.from_debug("!megumin")
    response1 = Sue.debug_blocking_process_message(m)
    assert String.contains?(response1.body, "not found")

    m2 = Message.from_debug("!define megumin acute")
    response2 = Sue.debug_blocking_process_message(m2)
    assert String.contains?(response2.body, "updated")

    m3 = Message.from_debug("!megumin")
    response3 = Sue.debug_blocking_process_message(m3)
    assert response3.body == "acute"

    m4 = Message.from_debug("!phrases")
    response4 = Sue.debug_blocking_process_message(m4)
    assert String.contains?(response4.body, "megumin")
  end

  test "poll" do
    Schema.debug_clear_collections()

    m = Message.from_debug("!vote a")
    r = Sue.debug_blocking_process_message(m)
    assert String.contains?(r.body, "not exist")

    m = Message.from_debug("!poll topic, option1, option2")
    r = Sue.debug_blocking_process_message(m)
    assert String.contains?(r.body, "option2")

    m = Message.from_debug("!vote a")
    r = Sue.debug_blocking_process_message(m)
    assert String.contains?(r.body, "(1) a.")

    m = Message.from_debug("!vote b")
    r = Sue.debug_blocking_process_message(m)
    assert String.contains?(r.body, "(1) b.")

    m = Message.from_debug("!poll topic, option1, option2, option3")
    r = Sue.debug_blocking_process_message(m)
    assert String.contains?(r.body, "option3")
  end

  test "ratelimit" do
    Schema.debug_clear_collections()

    m = Message.from_debug("!h_ratetest")
    r = Sue.debug_blocking_process_message(m)
    assert String.contains?(r.body, "good")

    m = Message.from_debug("!h_ratetest")
    r = Sue.debug_blocking_process_message(m)
    assert String.contains?(r.body, "good")

    m = Message.from_debug("!h_ratetest")
    r = Sue.debug_blocking_process_message(m)
    assert String.contains?(r.body, "deny")
  end
end
