%%%-------------------------------------------------------------------
%%% @author Ruben
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 12. Aug 2021 9:40 PM
%%%-------------------------------------------------------------------
-module(master).
-author("Ruben").

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-import(graph, [generate_graph/1, generate_graph/3]).

-define(SERVER, master).
-define(SERVERS_FILENAME, "InputFiles/servers.txt").

-record(master_state, {servers, namePID}).
-record(request, {name, type, level}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Spawns the server and registers the local name (unique)
-spec(start_link() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  {ok, PID} = gen_server:start_link({global, ?SERVER}, ?MODULE, [], []),
  register(master, PID),
  gen_server:cast({master, node()}, init),
  {ok, PID}.

%%%===================================================================
%%% gen_server callbacks - init
%%%===================================================================

%% @private
%% @doc Initializes the server
-spec(init(Args :: term()) ->
  {ok, State :: #master_state{}} | {ok, State :: #master_state{}, timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).

init([]) ->
  io:format("Master started.~n"),
  delete_all_backups(),
  {ok, #master_state{}}.

%%%===================================================================
%%% gen_server callbacks - handle_call
%%%===================================================================

%% @private
%% @doc Handling call messages
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #master_state{}) ->
  {reply, Reply :: term(), NewState :: #master_state{}} |
  {reply, Reply :: term(), NewState :: #master_state{}, timeout() | hibernate} |
  {noreply, NewState :: #master_state{}} |
  {noreply, NewState :: #master_state{}, timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: #master_state{}} |
  {stop, Reason :: term(), NewState :: #master_state{}}).

%% Return as a reply the name associated to the NameId
handle_call({name, NameID}, From, State = #master_state{}) ->
  case State#master_state.namePID of
    undefined -> {reply, not_available, State};
    PID ->
      spawn_monitor(fun() -> gen_server:reply(From, fetch_name(NameID, PID)) end),
      {noreply, State}
  end;

%% Handle request from client
handle_call({request, Request = #request{}}, From, State = #master_state{}) ->
  spawn_link(fun() -> process_request(Request, From, State#master_state.servers) end),
  {noreply, State};

%% Handle request from client
handle_call({request, Name, Type, Level}, From, State = #master_state{}) ->
  Request = #request{name = Name, type = Type, level = Level},
  spawn_link(fun() -> process_request(Request, From, State#master_state.servers) end),
  {noreply, State};

%% Handle distribute file request from server
handle_call({distribute_files, Node, FileName}, From, State = #master_state{}) ->
  spawn_link(fun() -> distribute_files(Node, FileName, State#master_state.servers, From) end),
  {noreply, State};

%% Other request -> not handled
handle_call(_Request, _From, State = #master_state{}) ->
  {reply, unknown_request, State}.

%%%===================================================================
%%% gen_server callbacks - handle_cast
%%%===================================================================

%% @private
%% @doc Handling cast messages
-spec(handle_cast(Request :: term(), State :: #master_state{}) ->
  {noreply, NewState :: #master_state{}} |
  {noreply, NewState :: #master_state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #master_state{}}).

%% Init the system
handle_cast(init, State = #master_state{}) ->
  Start = os:timestamp(),

  {NodesAlive, NamePID} = dataInit:start_distribution(),  % Distribute the data to the servers
  broadcast(NodesAlive, cast, stop_init), % Tell the servers the init is over

  io:format("Distributed data to ~p servers in ~p ms.~n", [length(NodesAlive), round(timer:now_diff(os:timestamp(), Start) / 1000)]),
  {noreply, State#master_state{servers = NodesAlive, namePID = NamePID}};

%% Handle Server Down
handle_cast({server_down, Node, Reason}, State = #master_state{}) ->
  NewList = State#master_state.servers -- [Node],

  dataInit:redistribute(NewList, Node),     % Tell to one of the servers running to handle the data of the server down

  io:format("~nServer ~p is DOWN: ~p\t~p Server(s) Running!~n~n", [Node, Reason, length(NewList)]),
  {noreply, State#master_state{servers = NewList}};

handle_cast(_Request, State = #master_state{}) ->
  {noreply, State}.

%%%===================================================================
%%% gen_server callbacks - handle_info
%%%===================================================================

%% @private
%% @doc Handling all non call/cast messages
-spec(handle_info(Info :: timeout() | term(), State :: #master_state{}) ->
  {noreply, NewState :: #master_state{}} |
  {noreply, NewState :: #master_state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #master_state{}}).

handle_info(_Info, State = #master_state{}) ->
  {noreply, State}.

%%%===================================================================
%%% gen_server callbacks - terminate
%%%===================================================================

%% @private
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #master_state{}) -> term()).
terminate(_Reason, State = #master_state{}) ->
  broadcast(State#master_state.servers, cast, master_down).

%%%===================================================================
%%% gen_server callbacks - code_change
%%%===================================================================

%% @private
%% @doc Convert process state when code is changed
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #master_state{},
    Extra :: term()) ->
  {ok, NewState :: #master_state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State = #master_state{}, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

fetch_name(NameID, DB) ->
  DB ! {self(), NameID},
  receive
    Name -> Name
  end.

broadcast([], _, _) -> ok;
broadcast(Servers, Type, Message) ->
  io:format("Sending Message (~p) to ~p (~p servers).~n", [Message, Servers, length(Servers)]),
  case Type of
    cast -> lists:foreach(fun(S) -> gen_server:cast({server, S}, Message) end, Servers);
    call -> lists:map(fun(S) -> gen_server:call({server, S}, Message) end, Servers);
    pcall -> pmap:map(fun(S) -> gen_server:call({server, S}, Message, 10000) end, Servers);
    _ -> io:format("ERROR")
  end.


process_request(Request = #request{}, From, Servers) ->
  io:format("Received a new Request: Name = ~p\tType = ~p\tLevel = ~p~n", [Request#request.name, Request#request.type, Request#request.level]),
  G = digraph:new(),
  Root = digraph:add_vertex(G, Request#request.name, Request#request.name),
  Set = sets:new(),
  process_request(G, Root, sets:add_element(Request#request.name, Set), Request, 1, Servers),
  gen_server:reply(From, {length(digraph:edges(G)), length(digraph:vertices(G))}),
  FileName = generate_graph(G, Root, Request#request.type),
  % FileName = generate_graph(G),
  Reply = os:cmd(io_lib:format("xdg-open ~s", [FileName])),
  io:format("Opening file ~s: ~p~n", [FileName, Reply]).

process_request(_, _, _, Request = #request{}, Level, _) when Level =:= Request#request.level -> ok;

process_request(G, V, Set, Request = #request{}, Level, Servers) ->
  Children = parse_reply(broadcast(Servers, pcall, {request, Request#request{name = V, level = Level}})),
  {AddedVertices, UpdatedSet} = update_graph(G, V, Set, Children, []),
  io:format("Level ~p: ~s~n", [Level, string:join(AddedVertices, ", ")]),
  lists:foreach(fun(Vertex) -> process_request(G, Vertex, UpdatedSet, Request, Level + 1, Servers) end, AddedVertices).


update_graph(_, _, Set, [], V) -> {V, Set};
update_graph(G, V, Set, [Name | Next], Vertices) ->
  case sets:is_element(Name, Set) of
    true -> update_graph(G, V, Set, Next, Vertices);
    false ->
      V1 = digraph:add_vertex(G, Name, Name),
      digraph:add_edge(G, V, V1),
      update_graph(G, V, sets:add_element(Name, Set), Next, [V1 | Vertices])
  end.


parse_reply(List) -> parse_reply(List, []).
parse_reply([], Reply) -> sets:to_list(sets:from_list(Reply));
parse_reply([badarg | _], _) -> badarg;
parse_reply([notfound | Next], Reply) -> parse_reply(Next, Reply);
parse_reply([R | Next], Reply) -> parse_reply(Next, R ++ Reply).


distribute_files(Node, FileName, Servers, From) ->
  {ok, Bin} = file:read_file(FileName),
  Reply = pmap:map(
    fun(S) ->
      ok = rpc:call(S, file, write_file, [FileName, Bin])
    end,
    Servers -- [Node]),
  ok = file:delete(FileName),
  io:format("Distributed data from ~p to other servers -> ~p~n", [Node, Reply]),

  gen_server:reply(From, Reply).

%%%===================================================================
%%% Internal functions - get_ip
%%%===================================================================

%% @doc Fin Ip Address of machine
-spec get_ip() -> ok.
get_ip() ->
  {ok, List} = inet:getifaddrs(),
  hd([IP || {_, Opts} <- List, {addr, IP} <- Opts, size(IP) == 4, IP =/= {127, 0, 0, 1}]).

%%%===================================================================
%%% Internal functions - delete_all_backups
%%%===================================================================

%% @doc Delete all the files in the working directory that start with table
-spec delete_all_backups() -> ok.
delete_all_backups() ->
  {ok, Dir} = file:get_cwd(),
  {ok, Files} = file:list_dir(Dir),
  lists:foreach(
    fun(File) ->
      case hd(string:split(File, "_")) == "table" of
        true -> file:delete(File);
        false -> ok
      end
    end,
    Files).
