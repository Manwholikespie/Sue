defmodule Mix.Tasks.Sue.Migrate.Arango do
  @shortdoc "One-shot migration of Sue's data from ArangoDB into Sue.Graph."

  @moduledoc """
  Reads every Arango collection Sue ever wrote to and rewrites it as vertices
  and edges in the new Khepri-backed `Sue.Graph`.

  Uses the `config :arangox, ...` block from `config/config.secret.exs`, so make
  sure Arango is reachable before running. After a successful migration you can
  drop:

    * the `config :arangox, ...` block in `config/config.secret.exs`
    * `{:arangox, ...}` from `apps/sue/mix.exs` deps
    * the ArangoDB container in `docker-compose.yml`

  Usage:

      mix sue.migrate.arango            # writes to Sue.Graph, prints counts
      mix sue.migrate.arango --dry-run  # reads and plans, writes nothing

  ## Id translation

  Sue vertices that have a natural key (`PlatformAccount`, `Chat`, `Poll`) get a
  deterministic id derived from that key — so running the migration twice is
  safe for them. `Account` and `Defn` have no natural key; each gets a fresh
  ULID, and an in-memory `old_arango_id → new_ulid` map keeps edges consistent.

  Re-running the task generates *new* ULIDs for Accounts/Defns, so the intended
  workflow is "run once, verify, cut over."
  """

  use Mix.Task

  require Logger

  alias Sue.Graph
  alias Sue.DB.Schema
  alias Sue.Models.{Account, Chat, Defn, PlatformAccount, Poll}

  @arango_vertex_collections ~w(sue_platformaccounts sue_chats sue_users sue_defns sue_polls)
  @arango_edge_collections ~w(
    sue_user_by_platformaccount
    sue_user_in_chat
    sue_defn_by_user
    sue_defn_by_chat
    sue_poll_by_chat
  )

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: [dry_run: :boolean])
    dry_run? = Keyword.get(opts, :dry_run, false)

    Mix.Task.run("app.start")

    {:ok, conn} = connect_arango()

    Logger.info("Reading vertices from Arango…")
    {id_map, vertex_writes} = read_vertices(conn)

    Logger.info("Reading edges from Arango…")
    edge_writes = read_edges(conn, id_map)

    if dry_run? do
      Logger.info(
        "[dry-run] would write #{length(vertex_writes)} vertices, #{length(edge_writes)} edges"
      )
    else
      Logger.info("Writing vertices to Sue.Graph…")
      Enum.each(vertex_writes, &Graph.put/1)

      Logger.info("Writing edges to Sue.Graph…")
      Enum.each(edge_writes, fn {from, type, to} -> Graph.link(from, type, to) end)

      Graph.sync()
      Logger.info("Done. Vertices: #{length(vertex_writes)}  Edges: #{length(edge_writes)}")
    end
  end

  # ---------- Arango I/O ----------

  defp connect_arango do
    endpoints = Application.fetch_env!(:arangox, :endpoints)
    username = Application.fetch_env!(:arangox, :username)
    password = Application.fetch_env!(:arangox, :password)
    dbname = Application.get_env(:subaru, :dbname, "subaru_#{Mix.env()}")

    Arangox.start_link(
      endpoints: endpoints,
      username: username,
      password: password,
      database: dbname,
      client: Arangox.MintClient
    )
  end

  # Stream all docs from an Arango collection.
  defp stream_collection(conn, name) do
    Stream.resource(
      fn -> {:start, name} end,
      fn
        {:start, coll} ->
          query = "FOR doc IN #{coll} RETURN doc"

          Arangox.transaction(conn, fn c ->
            cursor = Arangox.cursor(c, query, %{})
            docs = cursor |> Enum.flat_map(&(&1.body["result"] || []))
            {docs, :done}
          end)
          |> case do
            {:ok, {docs, :done}} -> {docs, :done}
            {:error, _} = err -> throw(err)
          end

        :done ->
          {:halt, :done}
      end,
      fn _ -> :ok end
    )
  end

  # ---------- Vertex reading + id translation ----------

  # Walk all vertex collections, produce (a) an old→new id map for edge fixup,
  # and (b) the list of typed vertex structs ready to Graph.put.
  defp read_vertices(conn) do
    Enum.reduce(@arango_vertex_collections, {%{}, []}, fn coll, {id_map, writes} ->
      docs = stream_collection(conn, coll) |> Enum.to_list()
      Logger.info("  #{coll}: #{length(docs)} docs")

      Enum.reduce(docs, {id_map, writes}, fn doc, {acc_map, acc_writes} ->
        {new_id, vertex} = to_vertex(coll, doc, acc_map)
        {Map.put(acc_map, doc["_id"], new_id), [vertex | acc_writes]}
      end)
    end)
  end

  defp to_vertex("sue_platformaccounts", doc, _id_map) do
    platform = atomize(doc["platform"])
    external = doc["id"]
    id = PlatformAccount.id_for(platform, external)
    {id, %PlatformAccount{id: id, platform_id: {platform, external}}}
  end

  defp to_vertex("sue_chats", doc, _id_map) do
    platform = atomize(doc["platform"])
    external = doc["id"]
    id = Chat.id_for(platform, external)

    {id,
     %Chat{
       id: id,
       platform_id: {platform, external},
       is_direct: doc["is_direct"] == true,
       is_ignored: doc["is_ignored"] == true
     }}
  end

  defp to_vertex("sue_users", doc, _id_map) do
    id = Graph.gen_id()

    {id,
     %Account{
       id: id,
       name: doc["name"] || "",
       handle: doc["handle"] || "",
       is_premium: doc["is_premium"] == true,
       is_admin: doc["is_admin"] == true,
       is_banned: doc["is_banned"] == true,
       is_ignored: doc["is_ignored"] == true,
       ban_reason: doc["ban_reason"] || ""
     }}
  end

  defp to_vertex("sue_defns", doc, _id_map) do
    id = Graph.gen_id()

    {id,
     %Defn{
       id: id,
       var: doc["var"],
       val: doc["val"],
       kind: atomize(doc["type"]),
       date_created: doc["date_created"],
       date_modified: doc["date_modified"]
     }}
  end

  defp to_vertex("sue_polls", doc, id_map) do
    # Poll id is derived from the (translated) chat id, so we need the chat
    # map already built when polls run — guaranteed by the collection order.
    new_chat_id = Map.fetch!(id_map, doc["chat_id"])
    id = Poll.id_for(new_chat_id)

    {id,
     %Poll{
       id: id,
       chat_id: new_chat_id,
       topic: doc["topic"],
       options: doc["options"] || [],
       votes: doc["votes"] || %{},
       interface: atomize(doc["interface"] || "standard")
     }}
  end

  # ---------- Edge reading ----------

  defp read_edges(conn, id_map) do
    Enum.flat_map(@arango_edge_collections, fn coll ->
      docs = stream_collection(conn, coll) |> Enum.to_list()
      type = edge_type_for(coll)
      Logger.info("  #{coll}: #{length(docs)} docs")

      Enum.flat_map(docs, &translate_edge(&1, type, id_map))
    end)
  end

  defp translate_edge(doc, type, id_map) do
    with {:ok, from} <- Map.fetch(id_map, doc["_from"]),
         {:ok, to} <- Map.fetch(id_map, doc["_to"]) do
      [{from, type, to}]
    else
      :error ->
        Logger.warning("  dropping dangling edge #{inspect(doc["_id"])}")
        []
    end
  end

  defp edge_type_for("sue_user_in_chat"), do: Schema.user_in_chat()
  defp edge_type_for("sue_defn_by_user"), do: Schema.defn_by_user()
  defp edge_type_for("sue_defn_by_chat"), do: Schema.defn_by_chat()
  defp edge_type_for("sue_poll_by_chat"), do: Schema.poll_by_chat()
  defp edge_type_for("sue_user_by_platformaccount"), do: Schema.account_for_platform_account()

  # ---------- Misc ----------

  defp atomize(value) when is_atom(value), do: value
  defp atomize(value) when is_binary(value), do: String.to_existing_atom(value)
end
