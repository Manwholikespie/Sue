defmodule Subaru.Query do
  require Logger

  @query_debug Application.compile_env(:sue, :query_debug, false)

  @moduledoc """
  The end goal is to have a stable wrapper for our DB that feels as good to use
    as elixir does, maybe even Mnesia inspired.
  """
  defstruct [:q, :bindvars, :statement, :context, :depth, :writes, :reads]

  alias :queue, as: Queue
  alias __MODULE__

  @type queue() :: Queue.queue()

  @type t() :: %__MODULE__{
          q: queue(),
          bindvars: Map.t(),
          statement: [bitstring()],
          context: [atom()],
          depth: integer(),
          writes: MapSet.t(),
          reads: MapSet.t()
        }

  @type literal() :: integer() | bitstring() | atom()
  @type relational_operator() :: :> | :>= | :< | :<= | :== | :!=
  @type logical_operator() :: :and | :or
  @type edge_direction() :: :any | :outbound | :inbound

  @type conditional() :: {relational_operator(), bitstring(), literal()}
  @type boolean_expression() ::
          {logical_operator(), conditional(), conditional()}
          | conditional()
          | dof_boolean()

  ## Document-Object Functions
  @type dof_boolean() ::
          {:is_same_collection, bitstring(), literal()}
          | {:has, map(), bitstring()}

  # TODO: Someday I'll get around to implementing all of these.
  # (Or not, now that Arango has dropped support for MacOS.)
  # Boolean:
  #   HAS()
  #   IS_SAME_COLLECTION()

  # Number:
  #   COUNT()
  #   LENGTH()
  #   MATCHES() (if returnIndex is enabled)

  # Array:
  #   ATTRIBUTES()
  #   VALUES()

  # Object:
  #   KEEP()
  #   KEEP_RECURSIVE()
  #   MERGE()
  #   MERGE_RECURSIVE()
  #   PARSE_IDENTIFIER()
  #   UNSET()
  #   UNSET_RECURSIVE()
  #   ZIP()

  # Any:
  #   TRANSLATE()
  #   VALUE()

  @spec new :: Query.t()
  def new() do
    %Query{
      q: Queue.new(),
      bindvars: %{},
      statement: [],
      context: [:root],
      depth: 0,
      writes: MapSet.new(),
      reads: MapSet.new()
    }
  end

  @spec let(Query.t(), atom(), any()) :: Query.t()
  def let(q, variableName, expression) do
    item = {:let, variableName, expression}
    push(q, item)
  end

  @spec for(t, atom(), bitstring()) :: t
  def for(q, variableName, collection) do
    item = {:for, variableName, collection}
    push(q, item)
  end

  @spec insert(t, any(), bitstring()) :: t
  def insert(q, doc, collection) do
    item = {:insert, doc, collection}
    push(q, item)
  end

  @spec upsert(t, any(), any(), any(), bitstring()) :: t
  def upsert(q, searchdoc, insertdoc, updatedoc, collection) do
    item = {:upsert, searchdoc, insertdoc, updatedoc, collection}
    push(q, item)
  end

  @doc """
  Similar to upsert, but uses REPLACE instead of UPDATE to completely replace documents rather than update fields.

  ## Parameters

  - `q`: The Query struct, representing the current state of the query being built.
  - `searchdoc`: The document to search for.
  - `insertdoc`: The document to insert if no match is found.
  - `replacedoc`: The document that will completely replace the existing doc if found.
  - `collection`: The name of the collection to operate on.

  ## Example

      Query.new()
      |> Query.repsert(%{name: "user1"}, %{name: "user1", active: true}, %{name: "user1", active: false}, "users")
      |> Query.exec()

  This will replace any document with name "user1" with the new document containing only name and active fields.
  Any other fields in the original document will be removed.
  """
  @spec repsert(t, any(), any(), any(), bitstring()) :: t
  def repsert(q, searchdoc, insertdoc, replacedoc, collection) do
    item = {:repsert, searchdoc, insertdoc, replacedoc, collection}
    push(q, item)
  end

  @doc """
  Updates a document in a specified collection with given key expression and new document data.

  ## Parameters

  - `q`: The Query struct, representing the current state of the query being built.
  - `keyExpression`: The key of the document to update, either as "123456" or "myCollection/123456"
  - `doc`: A map containing the document's new data.
  - `collection`: The name of the collection containing the document.

  ## Examples

      Query.new()
      |> Query.update_with("123456", %{field: "new value"}, "myCollection")
      |> Query.exec()

  This updates the document with key "123456" in "myCollection", setting its "field" to "new value".

      Query.new()
      |> Query.update_with("people/123456", %{field: "new value"}, "people")
      |> Query.exec()

  This also updates the document with key "123456" in "people", assuming "people/123456" is provided as a key expression.
  """
  @spec update_with(t, bitstring(), any(), bitstring()) :: t
  def update_with(q, keyExpression, doc, collection) do
    item = {:update_with, keyExpression, doc, collection}
    push(q, item)
  end

  @doc """
  Replaces the document at a given key.

  `keyExpression` is the value of the document ._key

  `updatedoc` can be either a map representing a document, or a DOF call written
  as a literal.

  `collection` is the ArangoDB collection being modified.

  ## Example

  Query.new()
  |> Query.for(:x, "sue_users")
  |> Query.filter({:!=, "x.id", nil})
  |> Query.replace_with("x._key", "UNSET(x, ['id', 'platform'])", "sue_users")
  """
  def replace_with(q, keyExpression, updatedoc, collection) do
    item = {:replace_with, keyExpression, updatedoc, collection}
    push(q, item)
  end

  def remove(q, variableName, collection) do
    item = {:remove, variableName, collection}
    push(q, item)
  end

  def traverse_for_v(q, ecolls, direction, startvert, min, max) do
    item = {:traverse_for, ecolls, direction, startvert, min, max}
    push(q, item)
  end

  @doc """
  Perform a graph traversal on one or more edge collections.
  """
  @spec traverse(t(), [bitstring(), ...] | bitstring(), atom(), bitstring(), any(), any()) :: t()
  def traverse(q, ecolls, direction, startvert, min, max) when is_list(ecolls) do
    item = {:traverse, ecolls, direction, startvert, min, max}
    push(q, item)
  end

  def traverse(q, ecoll, direction, startvert, min, max) when is_bitstring(ecoll) do
    traverse(q, [ecoll], direction, startvert, min, max)
  end

  def options(q, map) when is_map(map) and map_size(map) > 0 do
    item = {:options, map}
    push(q, item)
  end

  def options(q, %{}), do: q

  def filter(q, nil), do: q

  @spec filter(t, boolean_expression()) :: t
  def filter(q, expr) do
    item = {:filter, expr}
    push(q, item)
  end

  def return(q, expr) do
    item = {:return, expr}
    push(q, item)
  end

  @doc """
  Retrieves a document from a specified collection by its ID.

  ## Parameters

  - `q`: The Query struct, representing the current state of the query being built.
  - `collection`: The name of the collection from which to retrieve the document.
  - `id`: The unique identifier of the document to retrieve. Can be provided with or without the collection name prefix.
  """
  def get(q, collection, id) do
    cond do
      String.contains?(id, "/") ->
        return(q, "DOCUMENT(#{quoted(id)})")

      true ->
        return(q, "DOCUMENT(\"#{collection}/#{id}\")")
    end
  end

  def first(q, return \\ false) when is_boolean(return) do
    item = {:first, return}
    push(q, item)
  end

  def limit(q, amount) when is_integer(amount) do
    item = {:limit, amount}
    push(q, item)
  end

  @spec exec(t) :: DB.res()
  def exec(query) do
    {statement, bindvars, opts} = run(query)
    res = Subaru.DB.exec(statement, bindvars, opts)
    if @query_debug, do: Logger.debug(res |> inspect())
    res
  end

  @doc """
  Generate AQL code.
  """
  def run(query) do
    q = gen(query)

    statement = gen_statement(q)
    bindvars = q.bindvars
    opts = [write: MapSet.to_list(q.writes), read: MapSet.to_list(q.reads)]

    if @query_debug do
      # For debug purposes
      maxlinelen =
        statement
        |> String.split("\n")
        |> Enum.map(&String.length/1)
        |> Enum.max()

      logborder = String.duplicate("*", maxlinelen)
      Logger.debug("EXECUTING QUERY:\n#{logborder}\n#{statement}\n#{logborder}")
    end

    {statement, bindvars, opts}
  end

  @doc """
  Generate but don't execute AQL code.
  """
  def gen(query) do
    {q, item} = pop(query)
    gen(item, q)
  end

  defp gen(:empty, query), do: query

  # set var to query result
  defp gen({:let, variableName, %Query{} = expression}, query) do
    subquery = gen(expression)
    [expr_stmnt_head | expr_stmnt_tail] = subquery.statement

    query
    |> merge_bindvars(subquery.bindvars)
    |> merge_rw_colls(subquery.reads, subquery.writes)
    |> add_statement("LET #{variableName} = " <> expr_stmnt_head)
    |> add_statements(expr_stmnt_tail)
    |> gen()
  end

  # set var to literal
  defp gen({:let, variableName, expression}, query) do
    bindvar_id = generate_bindvar(expression)
    statement = "LET #{variableName} = " <> bindvar_id

    query
    |> add_statement(statement)
    |> add_bindvar(bindvar_id, expression)
    |> gen()
  end

  defp gen({:insert, doc, collection}, query) do
    doc_bindvar = generate_bindvar(doc)
    bv_coll = "@" <> generate_bindvar(collection)
    statement = "INSERT #{doc_bindvar} INTO #{bv_coll}"

    query
    |> add_statement(statement)
    |> add_bindvar(doc_bindvar, doc)
    |> add_bindvar(bv_coll, collection)
    |> add_write_coll(collection)
    |> gen()
  end

  defp gen({:upsert, searchdoc, insertdoc, updatedoc, collection}, query) do
    bv_sdoc = generate_bindvar(searchdoc)
    bv_idoc = generate_bindvar(insertdoc)
    bv_udoc = generate_bindvar(updatedoc)
    bv_coll = "@" <> generate_bindvar(collection)

    statement = "UPSERT #{bv_sdoc} INSERT #{bv_idoc} UPDATE #{bv_udoc} IN #{bv_coll}"

    query
    |> add_statement(statement)
    |> add_bindvar(bv_sdoc, searchdoc)
    |> add_bindvar(bv_idoc, insertdoc)
    |> add_bindvar(bv_udoc, updatedoc)
    |> add_bindvar(bv_coll, collection)
    |> add_write_coll(collection)
    |> gen()
  end

  defp gen({:repsert, searchdoc, insertdoc, replacedoc, collection}, query) do
    bv_sdoc = generate_bindvar(searchdoc)
    bv_idoc = generate_bindvar(insertdoc)
    bv_rdoc = generate_bindvar(replacedoc)
    bv_coll = "@" <> generate_bindvar(collection)

    statement = "UPSERT #{bv_sdoc} INSERT #{bv_idoc} REPLACE #{bv_rdoc} IN #{bv_coll}"

    query
    |> add_statement(statement)
    |> add_bindvar(bv_sdoc, searchdoc)
    |> add_bindvar(bv_idoc, insertdoc)
    |> add_bindvar(bv_rdoc, replacedoc)
    |> add_bindvar(bv_coll, collection)
    |> add_write_coll(collection)
    |> gen()
  end

  defp gen({:update_with, keyExpression, doc, collection}, query)
       when is_bitstring(keyExpression) do
    bv_doc = generate_bindvar(doc)
    bv_coll = "@" <> generate_bindvar(collection)

    # Directly handle the keyExpression format simplification
    formatted_key_expr =
      if keyExpression =~ ~r/^\d+$/ do
        # If the keyExpression is purely numeric, quote it
        quoted(keyExpression)
      else
        # Check if keyExpression is in "collection/numericKey" format and extract the numeric part
        case Regex.run(~r/^[\w-]+\/(\d+)$/, keyExpression) do
          [_, numeric_id] ->
            # If so, use the numeric ID, quoted
            quoted(numeric_id)

          _ ->
            # If not, use the keyExpression as is
            keyExpression
        end
      end

    statement = "UPDATE #{formatted_key_expr} WITH #{bv_doc} IN #{bv_coll}"

    query
    |> add_statement(statement)
    |> add_bindvar(bv_doc, doc)
    |> add_bindvar(bv_coll, collection)
    |> add_write_coll(collection)
    |> add_read_coll(collection)
    |> gen()
  end

  defp gen({:replace_with, keyExpression, doc, collection}, query) do
    bv_coll = "@" <> generate_bindvar(collection)

    statement = "REPLACE #{keyExpression} WITH #{doc} IN #{bv_coll}"

    query
    |> add_statement(statement)
    |> add_bindvar(bv_coll, collection)
    |> add_write_coll(collection)
    |> gen()
  end

  defp gen({:remove, variableName, collection}, query) do
    bv_coll = "@" <> generate_bindvar(collection)
    statement = "REMOVE #{variableName} IN #{bv_coll}"

    query
    |> add_statement(statement)
    |> add_bindvar(bv_coll, collection)
    |> add_write_coll(collection)
    |> gen()
  end

  defp gen({:for, variableName, collection}, query) do
    bv_coll = "@" <> generate_bindvar(collection)
    statement = "FOR #{variableName} IN #{bv_coll}"

    query
    |> add_statement(statement)
    |> add_bindvar(bv_coll, collection)
    |> add_read_coll(collection)
    |> gen()
  end

  defp gen({:traverse_for, ecolls, direction, startvert, min, max}, query) do
    startvert_bindvar_id = generate_bindvar(startvert)

    stm_min_max =
      if !is_nil(min) and !is_nil(max) do
        " #{min}..#{max}"
      else
        ""
      end

    statement =
      """
      FOR v IN#{stm_min_max} #{edgedir_to_str(direction)}
          #{startvert_bindvar_id}
          #{Enum.join(ecolls, ",")}
      """
      |> String.trim()

    query
    |> add_statement(statement)
    |> add_bindvar(startvert_bindvar_id, startvert)
    |> add_read_colls(ecolls)
    |> gen()
  end

  defp gen({:options, map}, query) do
    statement = "OPTIONS " <> map_to_str(map)

    query
    |> add_statement(statement)
    |> gen()
  end

  defp gen({:traverse, ecolls, direction, startvert, min, max}, query) do
    startvert_bindvar_id = generate_bindvar(startvert)

    stm_min_max =
      if !is_nil(min) and !is_nil(max) do
        " #{min}..#{max}"
      else
        ""
      end

    statement = """
    FOR v IN#{stm_min_max} #{edgedir_to_str(direction)}
        #{startvert_bindvar_id}
        #{Enum.join(ecolls, ",")}
        OPTIONS { order: "bfs", uniqueVertices: "global" }
        FILTER IS_SAME_COLLECTION("sue_defns", v)
        RETURN v
    """

    query
    |> add_statement(statement)
    |> add_bindvar(startvert_bindvar_id, startvert)
    |> add_read_colls(ecolls)
    |> gen()
  end

  defp gen({:filter, expr}, query) do
    statement = "FILTER " <> reduce_expr(expr)

    query
    |> add_statement(statement)
    |> gen()
  end

  defp gen({:return, expr}, query) do
    statement = "RETURN " <> expr

    query
    |> add_statement(statement)
    |> gen()
  end

  # query must be array query starting with FOR
  defp gen({:first, return}, %Query{statement: ["FOR" <> _ | _]} = query) do
    statement_prefix =
      if return do
        "RETURN "
      else
        ""
      end

    statement_start = statement_prefix <> "FIRST("
    statement_close = ")"

    Query.new()
    |> merge_bindvars(query.bindvars)
    |> merge_rw_colls(query.reads, query.writes)
    |> add_statement(statement_start)
    |> add_statements(query.statement)
    |> add_statement(statement_close)
    |> gen()
  end

  defp gen({:limit, amount}, query) do
    statement = "LIMIT #{amount}"

    query
    |> add_statement(statement)
    |> gen()
  end

  @spec gen_statement(t) :: bitstring()
  defp gen_statement(query) do
    helper_gen_statement(query, query.statement, "")
  end

  defp helper_gen_statement(_, [], acc), do: acc

  defp helper_gen_statement(query, [h | tail], acc) do
    {depth, context} =
      case h do
        "FOR " <> _ ->
          {query.depth + 1, context_update(query, :for)}

        "RETURN " <> _ ->
          {query.depth - 1, context_update(query, :pop)}

        ")" <> _ ->
          {query.depth - 1, context_update(query, :pop)}

        _ ->
          cond do
            String.ends_with?(h, "FIRST(") ->
              {query.depth + 1, context_update(query, :first)}

            true ->
              {query.depth, query.context}
          end
      end

    acc =
      (acc <> "\n" <> String.duplicate(" ", max(query.depth * 4, 0)) <> h)
      |> String.trim_leading()

    helper_gen_statement(%Query{query | depth: depth, context: context}, tail, acc)
  end

  @spec reduce_expr(boolean_expression()) :: bitstring()
  defp reduce_expr({:is_same_collection, collection, v}) do
    # TODO: HACK: yeah this is scuffed
    "IS_SAME_COLLECTION(#{quoted(collection)}, #{v})"
  end

  defp reduce_expr({op, var, val}) when is_bitstring(var) and is_bitstring(val) do
    "#{var} #{op} #{quoted(val)}"
  end

  defp reduce_expr({op, var, val}) when is_nil(val) do
    "#{var} #{op} null"
  end

  defp reduce_expr({op, var, val}) when is_number(val) do
    "#{var} #{op} #{val}"
  end

  defp reduce_expr({logical_operator, p, q}) do
    p_red = reduce_expr(p)
    q_red = reduce_expr(q)
    op = logical_op_to_str(logical_operator)

    "(#{p_red} #{op} #{q_red})"
  end

  @spec push(Query.t(), any()) :: Query.t()
  defp push(query, item) do
    %Query{query | q: Queue.in(item, query.q)}
  end

  @spec pop(Query.t()) :: {Query.t(), any()}
  defp pop(query) do
    case Queue.out(query.q) do
      {{:value, item}, tail} ->
        {%Query{query | q: tail}, item}

      {:empty, _} ->
        {query, :empty}
    end
  end

  @spec add_statement(Query.t(), binary()) :: Query.t()
  defp add_statement(query, statement) do
    add_statements(query, [statement])
  end

  @spec add_statement(Query.t(), [binary()]) :: Query.t()
  defp add_statements(query, statements) do
    %Query{query | statement: query.statement ++ statements}
  end

  @spec add_bindvar(t, bitstring(), any()) :: t
  defp add_bindvar(query, "@" <> key, value) do
    %Query{query | bindvars: Map.put(query.bindvars, key, value)}
  end

  @spec merge_bindvars(t, Map.t()) :: t
  defp merge_bindvars(query, bindvars) do
    %Query{query | bindvars: Map.merge(query.bindvars, bindvars)}
  end

  defp add_write_coll(query, coll) do
    %Query{query | writes: MapSet.put(query.writes, coll)}
  end

  defp add_read_coll(query, coll) do
    %Query{query | reads: MapSet.put(query.reads, coll)}
  end

  @spec add_read_colls(t(), [bitstring()]) :: t
  defp add_read_colls(query, colls) do
    %Query{query | reads: MapSet.union(query.reads, MapSet.new(colls))}
  end

  defp merge_rw_colls(query, reads, writes) do
    %Query{
      query
      | reads: MapSet.union(query.reads, reads),
        writes: MapSet.union(query.writes, writes)
    }
  end

  defp context_update(%Query{context: [:root]} = query, :pop) do
    query.context
  end

  defp context_update(query, :pop) do
    tl(query.context)
  end

  defp context_update(query, a) when is_atom(a) do
    [a | query.context]
  end

  # primarily used for generating unique ids for hashable objects.
  defp generate_bindvar(var) do
    id = :erlang.phash2(var, 10_000)
    "@var#{id}"
  end

  defp logical_op_to_str(:and), do: "&&"
  defp logical_op_to_str(:or), do: "||"

  @spec edgedir_to_str(edge_direction()) :: bitstring()
  defp edgedir_to_str(:outbound), do: "OUTBOUND"
  defp edgedir_to_str(:inbound), do: "INBOUND"
  defp edgedir_to_str(:any), do: "ANY"

  defp quoted(s) when is_bitstring(s) do
    "\"#{s}\""
  end

  defp map_to_str(m) do
    "{ " <>
      (m
       |> Enum.map(fn {k, v} -> "#{k}: \"#{v}\"" end)
       |> Enum.join(", ")) <> " }"
  end
end
