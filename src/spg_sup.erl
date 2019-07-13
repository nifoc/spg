%%%-------------------------------------------------------------------
%%% @author Maxim Fedorov <maximfca@gmail.com>
%%% @doc
%%% Simple top-level supervisor for spg application.
%%% Starts single scope 'spg' by default.
%%% @end
-module(spg_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%-------------------------------------------------------------------
%% API functions

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%%-------------------------------------------------------------------
%% Supervisor callbacks

%% Allow up to 10 crashes per minute. Why? Well, why not...
init([]) ->
    {ok, {
        #{strategy => one_for_one, intensity => 10, period => 60},
        [
            #{id => spg,
                start => {spg, start_link, []},
                restart => transient,
                shutdown => 1000,
                modules => [spg]
            }
        ]}}.
