%% @doc Safe graph inspection and deterministic text renderers.
-module(adk_graph_inspect).

-export([describe/1, to_dot/1, to_mermaid/1]).

-spec describe(map()) -> {ok, map()} | {error, term()}.
describe(Compiled) -> adk_graph_ir:from_compiled(Compiled).

-spec to_dot(map()) -> {ok, binary()} | {error, term()}.
to_dot(Compiled) ->
    case describe(Compiled) of
        {error, _} = Error -> Error;
        {ok, Descriptor} -> {ok, render_dot(Descriptor)}
    end.

-spec to_mermaid(map()) -> {ok, binary()} | {error, term()}.
to_mermaid(Compiled) ->
    case describe(Compiled) of
        {error, _} = Error -> Error;
        {ok, Descriptor} -> {ok, render_mermaid(Descriptor)}
    end.

render_dot(Descriptor) ->
    Nodes = maps:get(<<"nodes">>, Descriptor),
    Edges = maps:get(<<"edges">>, Descriptor),
    Index = node_index(Nodes),
    Entry = maps:get(<<"entry">>, Descriptor),
    NodeLines = [dot_node(Node, Index) || Node <- Nodes],
    EdgeLines = [dot_edge(Edge, Position, Index)
                 || {Position, Edge} <- enumerate(Edges)],
    unicode:characters_to_binary(
      ["digraph adk_graph {\n",
       "  rankdir=LR;\n",
       "  node [fontname=\"Helvetica\"];\n",
       "  start [shape=point,label=\"\"];\n",
       "  finish [shape=doublecircle,label=\"$end\"];\n",
       NodeLines,
       "  start -> ", maps:get(Entry, Index), ";\n",
       EdgeLines,
       "}\n"]).

dot_node(Node, Index) ->
    Id = maps:get(<<"id">>, Node),
    Type = maps:get(<<"type">>, Node),
    ["  ", maps:get(Id, Index), " [shape=", dot_shape(Type),
     ",label=\"", dot_escape(Id), "\\n(", dot_escape(Type),
     ")\"];\n"].

dot_edge(Edge, Position, Index) ->
    From = maps:get(maps:get(<<"from">>, Edge), Index),
    To = maps:get(<<"to">>, Edge),
    Label = edge_label(Edge),
    case To of
        null ->
            Dynamic = ["dynamic_", integer_to_list(Position)],
            ["  ", Dynamic,
             " [shape=diamond,label=\"dynamic route\"];\n",
             "  ", From, " -> ", Dynamic,
             " [style=dashed", dot_label(Label), "];\n"];
        <<"$end">> ->
            ["  ", From, " -> finish", dot_attributes(Label), ";\n"];
        _ ->
            ["  ", From, " -> ", maps:get(To, Index),
             dot_attributes(Label), ";\n"]
    end.

dot_shape(<<"fork">>) -> "diamond";
dot_shape(<<"branch">>) -> "diamond";
dot_shape(<<"dynamic">>) -> "diamond";
dot_shape(<<"loop">>) -> "hexagon";
dot_shape(<<"join">>) -> "circle";
dot_shape(<<"agent">>) -> "ellipse";
dot_shape(_Type) -> "box".

dot_attributes(null) -> "";
dot_attributes(Label) -> [" [label=\"", dot_escape(Label), "\"]"].

dot_label(null) -> "";
dot_label(Label) -> [",label=\"", dot_escape(Label), "\""].

dot_escape(Value) ->
    B0 = to_binary(Value),
    B1 = binary:replace(B0, <<"\\">>, <<"\\\\">>, [global]),
    B2 = binary:replace(B1, <<"\"">>, <<"\\\"">>, [global]),
    B3 = binary:replace(B2, <<"\n">>, <<"\\n">>, [global]),
    binary:replace(B3, <<"\r">>, <<"\\r">>, [global]).

render_mermaid(Descriptor) ->
    Nodes = maps:get(<<"nodes">>, Descriptor),
    Edges = maps:get(<<"edges">>, Descriptor),
    Index = node_index(Nodes),
    Entry = maps:get(<<"entry">>, Descriptor),
    NodeLines = [mermaid_node(Node, Index) || Node <- Nodes],
    EdgeLines = [mermaid_edge(Edge, Position, Index)
                 || {Position, Edge} <- enumerate(Edges)],
    unicode:characters_to_binary(
      ["flowchart TD\n",
       "  start((start))\n",
       "  finish(($end))\n",
       NodeLines,
       "  start --> ", maps:get(Entry, Index), "\n",
       EdgeLines]).

mermaid_node(Node, Index) ->
    Id = maps:get(<<"id">>, Node),
    Type = maps:get(<<"type">>, Node),
    Name = maps:get(Id, Index),
    Label = [mermaid_escape(Id), "<br/>", mermaid_escape(Type)],
    case Type of
        <<"fork">> -> ["  ", Name, "{\"", Label, "\"}\n"];
        <<"branch">> -> ["  ", Name, "{\"", Label, "\"}\n"];
        <<"dynamic">> -> ["  ", Name, "{\"", Label, "\"}\n"];
        <<"loop">> -> ["  ", Name, "{\"", Label, "\"}\n"];
        <<"join">> -> ["  ", Name, "((\"", Label, "\"))\n"];
        _ -> ["  ", Name, "[\"", Label, "\"]\n"]
    end.

mermaid_edge(Edge, Position, Index) ->
    From = maps:get(maps:get(<<"from">>, Edge), Index),
    To = maps:get(<<"to">>, Edge),
    Label = edge_label(Edge),
    case To of
        null ->
            Dynamic = ["dynamic_", integer_to_list(Position)],
            ["  ", Dynamic, "{\"dynamic route\"}\n",
             "  ", From, " ", mermaid_dashed_arrow(Label), " ",
             Dynamic, "\n"];
        <<"$end">> ->
            ["  ", From, " ", mermaid_arrow(Label), " finish\n"];
        _ ->
            ["  ", From, " ", mermaid_arrow(Label), " ",
             maps:get(To, Index), "\n"]
    end.

mermaid_arrow(null) -> "-->";
mermaid_arrow(Label) ->
    ["-->|", mermaid_escape(Label), "|"].

mermaid_dashed_arrow(null) -> "-.->";
mermaid_dashed_arrow(Label) ->
    ["-. ", mermaid_escape(Label), " .->"].

mermaid_escape(Value) ->
    B0 = to_binary(Value),
    B1 = binary:replace(B0, <<"&">>, <<"&amp;">>, [global]),
    B2 = binary:replace(B1, <<"<">>, <<"&lt;">>, [global]),
    B3 = binary:replace(B2, <<">">>, <<"&gt;">>, [global]),
    B4 = binary:replace(B3, <<"\"">>, <<"&quot;">>, [global]),
    B5 = binary:replace(B4, <<"\n">>, <<" ">>, [global]),
    binary:replace(B5, <<"\r">>, <<" ">>, [global]).

edge_label(Edge) ->
    case maps:get(<<"label">>, Edge, null) of
        null ->
            case maps:get(<<"kind">>, Edge) of
                <<"edge">> -> null;
                Kind -> Kind
            end;
        Label -> Label
    end.

node_index(Nodes) ->
    maps:from_list(
      [{maps:get(<<"id">>, Node),
        ["n", integer_to_list(Position)]}
       || {Position, Node} <- enumerate(Nodes)]).

enumerate(Items) -> lists:zip(lists:seq(1, length(Items)), Items).

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_binary(Value) -> unicode:characters_to_binary(Value).
