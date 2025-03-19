defmodule SubaruTest do
  use ExUnit.Case
  doctest Subaru

  test "create and delete collections" do
    {:ok, _} = Subaru.DB.create_collection("mycollection", :doc)
    {:ok, _} = Subaru.DB.remove_collection("mycollection")
    {:error, :dne} = Subaru.DB.remove_collection("augh")
  end

  test "insert" do
    {:ok, _} = Subaru.DB.create_collection("mycollection", :doc)

    # insert
    {:ok, id} = Subaru.insert(%{"name" => "Sue", "swaglevel" => 9001}, "mycollection")

    # find_one and compare
    expr = {:and, {:==, "x.name", "Sue"}, {:==, "x.swaglevel", 9001}}
    {:ok, doc} = Subaru.find_one("mycollection", expr)
    assert id == doc["_id"]

    # purposefully empty find_one
    emptyres_expr = {:and, {:==, "x.name", "Sue"}, {:==, "x.swaglevel", 0}}
    {:ok, :dne} = Subaru.find_one("mycollection", emptyres_expr)

    {:ok, _} = Subaru.DB.remove_collection("mycollection")
  end

  test "upsert" do
    {:ok, _} = Subaru.DB.create_collection("mycollection", :doc)

    # Define document to search/insert
    search_doc = %{"name" => "Okayu"}
    insert_doc = %{"name" => "Okayu", "swaglevel" => 8000, "hobby" => "eating"}
    update_doc = %{"swaglevel" => 9500}

    # Test insert case (document doesn't exist yet)
    {:ok, id} = Subaru.upsert(search_doc, insert_doc, update_doc, "mycollection")

    # Verify document was inserted with insert_doc values
    {:ok, doc} = Subaru.find_one("mycollection", {:==, "x.name", "Okayu"})
    assert doc["swaglevel"] == 8000
    assert doc["hobby"] == "eating"

    # Test update case (document exists) - partial update
    {:ok, id2} = Subaru.upsert(search_doc, insert_doc, update_doc, "mycollection")

    # Verify document was updated with update_doc values but kept original fields
    {:ok, updated_doc} = Subaru.find_one("mycollection", {:==, "x.name", "Okayu"})
    # Updated field
    assert updated_doc["swaglevel"] == 9500
    # Unchanged field
    assert updated_doc["hobby"] == "eating"
    # Same document ID
    assert id == id2

    # Test return_doc parameter
    {:ok, returned_doc} = Subaru.upsert(search_doc, insert_doc, update_doc, "mycollection", true)
    assert returned_doc["name"] == "Okayu"
    assert returned_doc["swaglevel"] == 9500

    {:ok, _} = Subaru.DB.remove_collection("mycollection")
  end

  test "repsert" do
    {:ok, _} = Subaru.DB.create_collection("mycollection", :doc)

    # Test repsert (REPLACE-based upsert)
    search_doc = %{"name" => "Korone"}

    insert_doc = %{
      "name" => "Korone",
      "swaglevel" => 8500,
      "hobby" => "gaming",
      "likes" => "bread"
    }

    replace_doc = %{"name" => "Korone", "affiliation" => "Hololive", "swaglevel" => 9800}

    # Insert a document using repsert (first time inserts)
    {:ok, id} = Subaru.repsert(search_doc, insert_doc, replace_doc, "mycollection")

    # Verify document was inserted with insert_doc values
    {:ok, doc} = Subaru.find_one("mycollection", {:==, "x.name", "Korone"})
    assert doc["swaglevel"] == 8500
    assert doc["hobby"] == "gaming"
    assert doc["likes"] == "bread"

    # Test replace case (document exists) - complete replacement
    {:ok, id2} = Subaru.repsert(search_doc, insert_doc, replace_doc, "mycollection")

    # Same document ID
    assert id == id2

    # Verify document was completely replaced with replace_doc (not merged)
    {:ok, replaced_doc} = Subaru.find_one("mycollection", {:==, "x.name", "Korone"})
    assert replaced_doc["name"] == "Korone"
    assert replaced_doc["swaglevel"] == 9800
    assert replaced_doc["affiliation"] == "Hololive"
    # These fields should be gone
    assert is_nil(replaced_doc["hobby"])
    # after replacement
    assert is_nil(replaced_doc["likes"])

    # Test return_doc parameter with repsert
    {:ok, returned_doc} =
      Subaru.repsert(search_doc, insert_doc, replace_doc, "mycollection", true)

    assert returned_doc["name"] == "Korone"
    assert returned_doc["swaglevel"] == 9800
    assert returned_doc["affiliation"] == "Hololive"
    assert is_nil(returned_doc["hobby"])
    assert is_nil(returned_doc["likes"])

    {:ok, _} = Subaru.DB.remove_collection("mycollection")
  end

  test "edges" do
    {:ok, _} = Subaru.DB.create_collection("vtuber_talents", :doc)
    {:ok, _} = Subaru.DB.create_collection("vtuber_agencies", :doc)
    {:ok, _} = Subaru.DB.create_collection("vtuber_talent_agency_contracts", :edge)

    # create vtuber talents
    {:ok, gura} = Subaru.insert(%{name: "Gura", subscribers: 3_940_000}, "vtuber_talents")

    {:ok, ame} = Subaru.insert(%{name: "Ame", subscribers: 1_650_000}, "vtuber_talents")
    {:ok, roa} = Subaru.insert(%{name: "Roa", subscribers: 353_000}, "vtuber_talents")

    # create vtuber agencies
    {:ok, hololive} = Subaru.insert(%{name: "Hololive", country: "JP"}, "vtuber_agencies")

    {:ok, nijisanji} = Subaru.insert(%{name: "Nijisanji", country: "JP"}, "vtuber_agencies")

    # link talents to agencies
    Subaru.insert_edge(gura, hololive, "vtuber_talent_agency_contracts")
    Subaru.insert_edge(ame, hololive, "vtuber_talent_agency_contracts")
    Subaru.insert_edge(roa, nijisanji, "vtuber_talent_agency_contracts")

    # confirm we can find what we added
    {:ok, verts} = Subaru.traverse_v(["vtuber_talent_agency_contracts"], :any, hololive)
    assert Enum.any?(verts, fn x -> x["_id"] == ame end)
    assert Enum.any?(verts, fn x -> x["_id"] == gura end)

    # cleanup
    {:ok, _} = Subaru.DB.remove_collection("vtuber_talents")
    {:ok, _} = Subaru.DB.remove_collection("vtuber_agencies")
    {:ok, _} = Subaru.DB.remove_collection("vtuber_talent_agency_contracts")
  end

  test "exists" do
    {:ok, _} = Subaru.DB.create_collection("chats", :doc)
    {:ok, _nash} = Subaru.insert(%{name: "Nash Ramblers"}, "chats")

    # Confirm exists
    expr = {:==, "x.name", "Nash Ramblers"}
    assert Subaru.exists?("chats", expr) == true

    # Confirm does not exist.
    expr2 = {:==, "x.name", "piranha"}
    assert Subaru.exists?("chats", expr2) == false
    {:ok, _} = Subaru.DB.remove_collection("chats")
  end

  test "update field" do
    {:ok, _} = Subaru.DB.create_collection("people", :doc)

    {:ok, jimmy_key} = Subaru.insert(%{name: "Jimmy", age: 100}, "people")
    %{"name" => "Jimmy"} = Subaru.get!("people", jimmy_key)

    {:ok, johnny_key} = Subaru.update_with(jimmy_key, %{name: "Johnny"}, "people")
    %{"name" => "Johnny"} = Subaru.get!("people", johnny_key)

    assert jimmy_key == johnny_key

    {:ok, _} = Subaru.DB.remove_collection("people")
  end
end
