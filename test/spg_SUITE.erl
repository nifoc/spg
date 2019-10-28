%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @doc
%%%     spg (scalable groups simplified) module test, based on
%%% scenarios generated by PropEr test, that originally failed.
%%% @end
%%% -------------------------------------------------------------------
-module(spg_SUITE).
-author("maximfca@gmail.com").

%% Test server callbacks
-export([
    suite/0,
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2,
    stop_proc/1
]).

%% Test cases exports
-export([
    app/0, app/1,
    spg/1,
    errors/0, errors/1,
    single/0, single/1,
    two/1,
    thundering_herd/0, thundering_herd/1,
    initial/1,
    netsplit/1,
    trisplit/1,
    foursplit/1,
    exchange/1,
    nolocal/1,
    double/1,
    scope_restart/1,
    missing_scope_join/1,
    disconnected_start/1,
    forced_sync/0, forced_sync/1,
    group_leave/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

suite() ->
    [{timetrap, {seconds, 10}}].

init_per_suite(Config) ->
    case erlang:is_alive() of
        false ->
            % verify epmd running (otherwise next call fails)
            (erl_epmd:names("localhost") =:= {error, address}) andalso ([] = os:cmd("epmd -daemon")),
            % start a random node name
            NodeName = list_to_atom(lists:concat([atom_to_list(?MODULE), "_", os:getpid()])),
            {ok, Pid} = net_kernel:start([NodeName, shortnames]),
            [{distribution, Pid} | Config];
        true ->
            Config
    end.

end_per_suite(Config) ->
    is_pid(proplists:get_value(distribution, Config)) andalso net_kernel:stop().

init_per_testcase(app, Config) ->
    Config;
init_per_testcase(TestCase, Config) ->
    {ok, _Pid} = spg:start_link(TestCase),
    Config.

end_per_testcase(app, _Config) ->
    application:stop(spg),
    ok;
end_per_testcase(TestCase, _Config) ->
    gen_server:stop(TestCase),
    ok.

all() ->
    [app, {group, basic}, {group, cluster}, {group, performance}].

groups() -> 
    [
        {basic, [parallel], [errors, spg, single]},
        {performance, [sequential], [thundering_herd]},
        {cluster, [parallel], [two, initial, netsplit, trisplit, foursplit,
            exchange, nolocal, double, scope_restart, missing_scope_join,
            disconnected_start, forced_sync, group_leave]}
    ].

sync(GS) ->
    _ = sys:log(GS, get).


forever() ->
    fun() -> receive after infinity -> ok end end.

%% @doc Kills process Pid and waits for it to exit using monitor,
%%      and yields after (for 1 ms).
-spec stop_proc(pid()) -> ok.
stop_proc(Pid) ->
    monitor(process, Pid),
    erlang:exit(Pid, kill),
    receive
        {'DOWN', _MRef, process, Pid, _Info} ->
            timer:sleep(1)
    end.

%% @doc starts peer node on this host.
%% Returns spawned node name, and a gen_tcp socket to talk to it using ?MODULE:rpc.
%% When Scope is undefined, no spg scope is started.
%% Name: short node name (no @host.domain allowed).
-spec spawn_node(Scope :: atom(), Node :: atom()) -> gen_node:dest().
spawn_node(Scope, Name) ->
    spawn_node(Scope, Name, true).

spawn_node(Scope, Name, AutoConnect) ->
    {ok, Peer} = local_node:start_link(Name, #{auto_connect => AutoConnect,
        connection => {undefined, undefined},
        connect_all => false, code_path => [code:lib_dir(spg, ebin)]}),
    {ok, _SpgPid} = gen_node:rpc(Peer, gen_server, start, [{local, Scope}, spg, [Scope], []]),
    Node = gen_node:get_node(Peer),
    {Node, Peer}.

%%--------------------------------------------------------------------
%% TEST CASES

spg(_Config) ->
    ?assertMatch({error, _}, spg:start_link()),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, self())),
    ?assertEqual([self()], spg:get_local_members(?FUNCTION_NAME)),
    ?assertEqual([?FUNCTION_NAME], spg:which_groups()),
    ?assertEqual([?FUNCTION_NAME], spg:which_local_groups()),
    ?assertEqual(ok, spg:leave(?FUNCTION_NAME, self())),
    ?assertEqual([], spg:get_members(?FUNCTION_NAME)),
    ?assertEqual([], spg:which_groups(?FUNCTION_NAME)),
    ?assertEqual([], spg:which_local_groups(?FUNCTION_NAME)).

app() ->
    [{doc, "Tests application start/stop functioning, supervision & scopes"}].

app(_Config) ->
    {ok, _Apps} = application:ensure_all_started(spg),
    ?assertNotEqual(undefined, whereis(spg)),
    ?assertNotEqual(undefined, ets:whereis(spg)),
    ok = application:stop(spg),
    ?assertEqual(undefined, whereis(spg)),
    ?assertEqual(undefined, ets:whereis(spg)),
    %
    application:set_env(spg, scopes, [?FUNCTION_NAME, two]),
    {ok, _Apps} = application:ensure_all_started(spg),
    ?assertNotEqual(undefined, whereis(?FUNCTION_NAME)),
    ?assertNotEqual(undefined, whereis(two)),
    ?assertNotEqual(undefined, ets:whereis(?FUNCTION_NAME)),
    ?assertNotEqual(undefined, ets:whereis(two)),
    application:stop(spg),
    ?assertEqual(undefined, whereis(?FUNCTION_NAME)),
    ?assertEqual(undefined, whereis(two)).

errors() ->
    [{doc, "Tests that errors are handled as expected, for example spg crashes when it needs to"}].

errors(_Config) ->
    % kill with 'info' and 'cast'
    {ok, _Pid} = gen_server:start({local, info}, spg, [info], []),
    ?assertException(error, badarg, spg:handle_info(garbage, garbage)),
    ?assertException(error, badarg, spg:handle_cast(garbage, garbage)),
    % kill with call
    {ok, Pid} = gen_server:start({local, second}, spg, [second], []),
    ?assertException(exit, {{badarg, _}, _}, gen_server:call(Pid, garbage, 100)).

single() ->
    [{doc, "Tests single node groups"}, {timetrap, {seconds, 5}}].

single(Config) when is_list(Config) ->
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, self())),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, [self(), self()])),
    ?assertEqual([self(), self(), self()], spg:get_local_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    ?assertEqual([self(), self(), self()], spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    ?assertEqual(not_joined, spg:leave(?FUNCTION_NAME, '$missing$', self())),
    ?assertEqual(ok, spg:leave(?FUNCTION_NAME, ?FUNCTION_NAME, [self(), self()])),
    ?assertEqual(ok, spg:leave(?FUNCTION_NAME, ?FUNCTION_NAME, self())),
    ?assertEqual([], spg:which_groups(?FUNCTION_NAME)),
    ?assertEqual([], spg:get_local_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    ?assertEqual([], spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    % double
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, self())),
    Pid = erlang:spawn(forever()),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, Pid)),
    Expected = lists:sort([Pid, self()]),
    ?assertEqual(Expected, lists:sort(spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME))),
    ?assertEqual(Expected, lists:sort(spg:get_local_members(?FUNCTION_NAME, ?FUNCTION_NAME))),
    %
    stop_proc(Pid),
    sync(?FUNCTION_NAME),
    ?assertEqual([self()], spg:get_local_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    ?assertEqual(ok, spg:leave(?FUNCTION_NAME, ?FUNCTION_NAME, self())),
    ok.

two(Config) when is_list(Config) ->
    {TwoPeer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    Pid = erlang:spawn(forever()),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, Pid)),
    ?assertEqual([Pid], spg:get_local_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    % first RPC must be serialised
    sync({?FUNCTION_NAME, TwoPeer}),
    ?assertEqual([Pid], rpc:call(TwoPeer, spg, get_members, [?FUNCTION_NAME, ?FUNCTION_NAME])),
    ?assertEqual([], rpc:call(TwoPeer, spg, get_local_members, [?FUNCTION_NAME, ?FUNCTION_NAME])),
    stop_proc(Pid),
    % again, must be serialised
    sync(?FUNCTION_NAME),
    ?assertEqual([], spg:get_local_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    ?assertEqual([], rpc:call(TwoPeer, spg, get_members, [?FUNCTION_NAME, ?FUNCTION_NAME])),
    %
    Pid2 = erlang:spawn(TwoPeer, forever()),
    Pid3 = erlang:spawn(TwoPeer, forever()),
    ?assertEqual(ok, rpc:call(TwoPeer, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, Pid2])),
    ?assertEqual(ok, rpc:call(TwoPeer, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, Pid3])),
    % serialise through the *other* node
    sync({?FUNCTION_NAME, TwoPeer}),
    ?assertEqual(lists:sort([Pid2, Pid3]),
        lists:sort(spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME))),
    % stop the peer
    gen_node:stop(Socket),
    % hope that 'nodedown' comes before we route our request
    sync(?FUNCTION_NAME),
    ?assertEqual([], spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    ok.

thundering_herd() ->
    [{doc, "Thousands of overlay network nodes sending sync to us, and we time out!"}, {timetrap, {seconds, 5}}].

thundering_herd(Config) when is_list(Config) ->
    GroupCount = 10000,
    SyncCount = 2000,
    % make up a large amount of groups
    [spg:join(?FUNCTION_NAME, {group, Seq}, self()) || Seq <- lists:seq(1, GroupCount)],
    % initiate a few syncs - and those are really slow...
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    PeerPid = erlang:spawn(Peer, forever()),
    PeerSpg = rpc:call(Peer, erlang, whereis, [?FUNCTION_NAME], 1000),
    %% WARNING: code below acts for white-box! %% WARNING
    FakeSync = [{{group, 1}, [PeerPid, PeerPid]}],
    [gen_server:cast(?FUNCTION_NAME, {sync, PeerSpg, FakeSync}) || _ <- lists:seq(1, SyncCount)],
    % next call must not timetrap, otherwise test fails
    spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, self()),
    gen_node:stop(Socket).

initial(Config) when is_list(Config) ->
    Pid = erlang:spawn(forever()),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, Pid)),
    ?assertEqual([Pid], spg:get_local_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    % first RPC must be serialised
    sync({?FUNCTION_NAME, Peer}),
    ?assertEqual([Pid], rpc:call(Peer, spg, get_members, [?FUNCTION_NAME, ?FUNCTION_NAME])),
    %
    ?assertEqual([], rpc:call(Peer, spg, get_local_members, [?FUNCTION_NAME, ?FUNCTION_NAME])),
    stop_proc(Pid),
    sync({?FUNCTION_NAME, Peer}),
    ?assertEqual([], rpc:call(Peer, spg, get_members, [?FUNCTION_NAME, ?FUNCTION_NAME])),
    gen_node:stop(Socket),
    ok.

netsplit(Config) when is_list(Config) ->
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    ?assertEqual(Peer, gen_node:rpc(Socket, erlang, node, [])), % just to test RPC
    RemoteOldPid = erlang:spawn(Peer, forever()),
    ?assertEqual(ok, rpc:call(Peer, spg, join, [?FUNCTION_NAME, '$invisible', RemoteOldPid])),
    % hohoho, partition!
    gen_node:disconnect(Socket),
    ?assertEqual(Peer, gen_node:rpc(Socket, erlang, node, [])), % just to ensure RPC still works
    RemotePid = gen_node:rpc(Socket, erlang, spawn, [forever()]),
    ?assertEqual([], gen_node:rpc(Socket, erlang, nodes, [])),
    ?assertEqual(ok, gen_node:rpc(Socket, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, RemotePid])), % join - in a partition!
    %
    ?assertEqual(ok, gen_node:rpc(Socket, spg, leave, [?FUNCTION_NAME, '$invisible', RemoteOldPid])),
    ?assertEqual(ok, gen_node:rpc(Socket, spg, join, [?FUNCTION_NAME, '$visible', RemoteOldPid])),
    ?assertEqual([RemoteOldPid], gen_node:rpc(Socket, spg, get_local_members, [?FUNCTION_NAME, '$visible'])),
    % join locally too
    LocalPid = erlang:spawn(forever()),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, LocalPid)),
    %
    ?assertNot(lists:member(Peer, nodes())), % should be no nodes in the cluster
    %
    pong = net_adm:ping(Peer),
    % now ensure sync happened
    Pids = lists:sort([RemotePid, LocalPid]),
    sync({?FUNCTION_NAME, Peer}),
    ?assertEqual(Pids, lists:sort(rpc:call(Peer, spg, get_members, [?FUNCTION_NAME, ?FUNCTION_NAME]))),
    ?assertEqual([RemoteOldPid], spg:get_members(?FUNCTION_NAME, '$visible')),
    gen_node:stop(Socket),
    ok.

trisplit(Config) when is_list(Config) ->
    {Peer, Socket1} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    _PeerPid1 = erlang:spawn(Peer, forever()),
    PeerPid2 = erlang:spawn(Peer, forever()),
    ?assertEqual(ok, rpc:call(Peer, spg, join, [?FUNCTION_NAME, three, PeerPid2])),
    gen_node:disconnect(Socket1),
    ?assertEqual(true, net_kernel:connect_node(Peer)),
    ?assertEqual(ok, rpc:call(Peer, spg, join, [?FUNCTION_NAME, one, PeerPid2])),
    % now ensure sync happened
    {Peer2, Socket2} = spawn_node(?FUNCTION_NAME, trisplit_second),
    ?assertEqual(true, rpc:call(Peer2, net_kernel, connect_node, [Peer])),
    ?assertEqual(lists:sort([node(), Peer]), lists:sort(rpc:call(Peer2, erlang, nodes, []))),
    sync({?FUNCTION_NAME, Peer2}),
    ?assertEqual([PeerPid2], rpc:call(Peer2, spg, get_members, [?FUNCTION_NAME, one])),
    gen_node:stop(Socket1),
    gen_node:stop(Socket2),
    ok.

foursplit(Config) when is_list(Config) ->
    Pid = erlang:spawn(forever()),
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, one, Pid)),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, two, Pid)),
    PeerPid1 = spawn(Peer, forever()),
    ?assertEqual(ok, spg:leave(?FUNCTION_NAME, one, Pid)),
    ?assertEqual(not_joined, spg:leave(?FUNCTION_NAME, three, Pid)),
    gen_node:disconnect(Socket),
    ?assertEqual(ok, gen_node:rpc(Socket, ?MODULE, stop_proc, [PeerPid1])),
    ?assertEqual(not_joined, spg:leave(?FUNCTION_NAME, three, Pid)),
    ?assertEqual(true, net_kernel:connect_node(Peer)),
    ?assertEqual([], spg:get_members(?FUNCTION_NAME, one)),
    ?assertEqual([], gen_node:rpc(Socket, spg, get_members, [?FUNCTION_NAME, one])),
    gen_node:stop(Socket),
    ok.

exchange(Config) when is_list(Config) ->
    {Peer1, Socket1} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    {Peer2, Socket2} = spawn_node(?FUNCTION_NAME, exchange_second),
    Pids10 = [gen_node:rpc(Socket1, erlang, spawn, [forever()]) || _ <- lists:seq(1, 10)],
    Pids2 = [gen_node:rpc(Socket2, erlang, spawn, [forever()]) || _ <- lists:seq(1, 10)],
    Pids11 = [gen_node:rpc(Socket1, erlang, spawn, [forever()]) || _ <- lists:seq(1, 10)],
    % kill first 3 pids from node1
    {PidsToKill, Pids1} = lists:split(3, Pids10),
    %
    ?assertEqual(ok, gen_node:rpc(Socket1, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, Pids10])),
    sync({?FUNCTION_NAME, Peer1}),
    ?assertEqual(lists:sort(Pids10), lists:sort(spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME))),
    [gen_node:rpc(Socket1, ?MODULE, stop_proc, [Pid]) || Pid <- PidsToKill],
    sync(?FUNCTION_NAME),
    sync({?FUNCTION_NAME, Peer1}),
    %
    Pids = lists:sort(Pids1 ++ Pids2 ++ Pids11),
    ?assert(lists:all(fun erlang:is_pid/1, Pids)),
    %
    gen_node:disconnect(Socket1),
    gen_node:disconnect(Socket2),
    %
    sync(?FUNCTION_NAME),
    ?assertEqual([], lists:sort(spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME))),
    %
    [?assertEqual(ok, gen_node:rpc(Socket2, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, Pid])) || Pid <- Pids2],
    [?assertEqual(ok, gen_node:rpc(Socket1, spg, join, [?FUNCTION_NAME, second, Pid])) || Pid <- Pids11],
    ?assertEqual(ok, gen_node:rpc(Socket1, spg, join, [?FUNCTION_NAME, third, Pids11])),
    % rejoin
    ?assertEqual(true, net_kernel:connect_node(Peer1)),
    ?assertEqual(true, net_kernel:connect_node(Peer2)),
    % need to sleep longer to ensure both nodes made the exchange
    sync(?FUNCTION_NAME),
    sync({?FUNCTION_NAME, Peer1}),
    sync({?FUNCTION_NAME, Peer2}),
    ?assertEqual(Pids, lists:sort(spg:get_members(?FUNCTION_NAME, second) ++ spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME))),
    ?assertEqual(lists:sort(Pids11), lists:sort(spg:get_members(?FUNCTION_NAME, third))),
    %
    {Left, Stay} = lists:split(3, Pids11),
    ?assertEqual(ok, gen_node:rpc(Socket1, spg, leave, [?FUNCTION_NAME, third, Left])),
    sync({?FUNCTION_NAME, Peer1}),
    sync(?FUNCTION_NAME),
    ?assertEqual(lists:sort(Stay), lists:sort(spg:get_members(?FUNCTION_NAME, third))),
    ?assertEqual(not_joined, gen_node:rpc(Socket1, spg, leave, [?FUNCTION_NAME, left, Stay])),
    ?assertEqual(ok, gen_node:rpc(Socket1, spg, leave, [?FUNCTION_NAME, third, Stay])),
    sync({?FUNCTION_NAME, Peer1}),
    sync(?FUNCTION_NAME),
    ?assertEqual([], lists:sort(spg:get_members(?FUNCTION_NAME, third))),
    sync({?FUNCTION_NAME, Peer1}),
    sync(?FUNCTION_NAME),
    %
    gen_node:stop(Socket1),
    gen_node:stop(Socket2),
    ok.

nolocal(Config) when is_list(Config) ->
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    RemotePid = spawn(Peer, forever()),
    ?assertEqual(ok, rpc:call(Peer, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, RemotePid])),
    ?assertEqual(ok, rpc:call(Peer, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, RemotePid])),
    ?assertEqual([], spg:get_local_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    gen_node:stop(Socket),
    ok.

double(Config) when is_list(Config) ->
    Pid = erlang:spawn(forever()),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, Pid)),
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, [Pid])),
    ?assertEqual([Pid, Pid], spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    sync(?FUNCTION_NAME),
    sync({?FUNCTION_NAME, Peer}),
    ?assertEqual([Pid, Pid], rpc:call(Peer, spg, get_members, [?FUNCTION_NAME, ?FUNCTION_NAME])),
    gen_node:stop(Socket),
    ok.

scope_restart(Config) when is_list(Config) ->
    Pid = erlang:spawn(forever()),
    ?assertEqual(ok, spg:join(?FUNCTION_NAME, ?FUNCTION_NAME, [Pid, Pid])),
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    RemotePid = spawn(Peer, forever()),
    ?assertEqual(ok, rpc:call(Peer, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, RemotePid])),
    sync({?FUNCTION_NAME, Peer}),
    ?assertEqual(lists:sort([RemotePid, Pid, Pid]), lists:sort(spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME))),
    % stop scope locally, and restart
    gen_server:stop(?FUNCTION_NAME),
    gen_server:start({local, ?FUNCTION_NAME}, spg, [?FUNCTION_NAME], []),
    % ensure remote pids joined, local are missing
    sync(?FUNCTION_NAME),
    sync({?FUNCTION_NAME, Peer}),
    sync(?FUNCTION_NAME),
    ?assertEqual([RemotePid], spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME)),
    gen_node:stop(Socket),
    ok.

missing_scope_join(Config) when is_list(Config) ->
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    ?assertEqual(ok, rpc:call(Peer, gen_server, stop, [?FUNCTION_NAME])),
    RemotePid = spawn(Peer, forever()),
    ?assertMatch({badrpc, {'EXIT', {noproc, _}}}, rpc:call(Peer, spg, join, [?FUNCTION_NAME, ?FUNCTION_NAME, RemotePid])),
    ?assertMatch({badrpc, {'EXIT', {noproc, _}}}, rpc:call(Peer, spg, leave, [?FUNCTION_NAME, ?FUNCTION_NAME, RemotePid])),
    gen_node:stop(Socket),
    ok.

disconnected_start(Config) when is_list(Config) ->
    {_Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME, false),
    ?assertEqual(ok, gen_node:rpc(Socket, gen_server, stop, [?FUNCTION_NAME])),
    ?assertMatch({ok, _Pid}, gen_node:rpc(Socket, gen_server, start,[{local, ?FUNCTION_NAME}, spg, [?FUNCTION_NAME], []])),
    ?assertEqual(ok, gen_node:rpc(Socket, gen_server, stop, [?FUNCTION_NAME])),
    RemotePid = gen_node:rpc(Socket, erlang, spawn, [forever()]),
    ?assert(is_pid(RemotePid)),
    gen_node:stop(Socket),
    ok.

forced_sync() ->
    [{doc, "This test was added when lookup_element was erroneously used instead of lookup, crashing spg with badmatch, and it tests rare out-of-order sync operations"}].

forced_sync(Config) when is_list(Config) ->
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    Pid = erlang:spawn(forever()),
    RemotePid = spawn(Peer, forever()),
    Expected = lists:sort([Pid, RemotePid]),
    spg:join(?FUNCTION_NAME, one, Pid),
    %
    ?assertEqual(ok, rpc:call(Peer, spg, join, [?FUNCTION_NAME, one, RemotePid])),
    RemoteScopePid = rpc:call(Peer, erlang, whereis, [?FUNCTION_NAME]),
    ?assert(is_pid(RemoteScopePid)),
    % hohoho, partition!
    gen_node:disconnect(Socket),
    ?assertEqual(true, net_kernel:connect_node(Peer)),
    % now ensure sync happened
    sync({?FUNCTION_NAME, Peer}),
    sync(?FUNCTION_NAME),
    ?assertEqual(Expected, lists:sort(spg:get_members(?FUNCTION_NAME, one))),
    % WARNING: this code uses spg as white-box, exploiting internals,
    %  only to simulate broken 'sync'
    % Fake Groups: one should disappear, one should be replaced, one stays
    % This tests handle_sync function.
    FakeGroups = [{one, [RemotePid, RemotePid]}, {?FUNCTION_NAME, [RemotePid, RemotePid]}],
    gen_server:cast(?FUNCTION_NAME, {sync, RemoteScopePid, FakeGroups}),
    % ensure it is broken well enough
    sync(?FUNCTION_NAME),
    ?assertEqual(lists:sort([RemotePid, RemotePid]), lists:sort(spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME))),
    ?assertEqual(lists:sort([RemotePid, RemotePid, Pid]), lists:sort(spg:get_members(?FUNCTION_NAME, one))),
    % simulate force-sync via 'discover' - ask peer to send sync to us
    gen_server:cast({?FUNCTION_NAME, Peer}, {discover, whereis(?FUNCTION_NAME)}),
    sync({?FUNCTION_NAME, Peer}),
    sync(?FUNCTION_NAME),
    ?assertEqual(Expected, lists:sort(spg:get_members(?FUNCTION_NAME, one))),
    ?assertEqual([], lists:sort(spg:get_members(?FUNCTION_NAME, ?FUNCTION_NAME))),
    % and simulate extra sync
    sync({?FUNCTION_NAME, Peer}),
    sync(?FUNCTION_NAME),
    ?assertEqual(Expected, lists:sort(spg:get_members(?FUNCTION_NAME, one))),
    %
    gen_node:stop(Socket),
    ok.

group_leave(Config) when is_list(Config) ->
    {Peer, Socket} = spawn_node(?FUNCTION_NAME, ?FUNCTION_NAME),
    RemotePid = erlang:spawn(Peer, forever()),
    Total = lists:duplicate(16, RemotePid),
    {Left, Remain} = lists:split(4, Total),
    % join 16 times!
    ?assertEqual(ok, rpc:call(Peer, spg, join, [?FUNCTION_NAME, two, Total])),
    ?assertEqual(ok, rpc:call(Peer, spg, leave, [?FUNCTION_NAME, two, Left])),
    %
    sync({?FUNCTION_NAME, Peer}),
    sync(?FUNCTION_NAME),
    ?assertEqual(Remain, spg:get_members(?FUNCTION_NAME, two)),
    %
    gen_node:stop(Socket),
    %
    sync(?FUNCTION_NAME),
    ?assertEqual([], spg:get_members(?FUNCTION_NAME, two)),
    ok.
