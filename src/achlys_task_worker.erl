%%%-------------------------------------------------------------------
%%% @author Igor Kopestenski <igor.kopestenski@uclouvain.be>
%%%     [https://github.com/Laymer/achlys]
%%% 2018, Universite Catholique de Louvain
%%% @doc
%%%
%%% @end
%%% Created : 05. Dec 2018 19:50
%%%-------------------------------------------------------------------
-module(achlys_task_worker).
-author("Igor Kopestenski <igor.kopestenski@uclouvain.be>").

-behaviour(gen_server).
% -behaviour(gen_flow).

-include("achlys.hrl").

%% API
-export([start_link/0]).
-export([start_task/1]).

%% gen_server callbacks
-export([init/1 ,
         handle_call/3 ,
         handle_cast/2 ,
         handle_info/2 ,
         terminate/2 ,
         code_change/3]).


%% gen_flow callbacks
% -export([read/1]).
% -export([process/2]).


%%====================================================================
%% Macros
%%====================================================================

-define(SERVER , ?MODULE).
% 65536 bytes of heap on 32-bit systems (4-byte words) i.e. 16384 words
% -define(MAX_HEAP_SIZE , (erlang:system_info(wordsize) * 1024 * 16)).
-define(MAX_HEAP_SIZE , 16384).

%%====================================================================
%% Records
%%====================================================================

-record(state , {
    % tasks :: [achlys:task(), {pid(), ref()}, pos_integer()],
    tasks :: dict:dict(term(), term())
    , available_slots :: pos_integer()
}).

-type state() :: #state{}.
% -record(state, {source}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Attempt to execute a given function if found in the task set.
-spec start_task(atom()) -> ok.
start_task(TaskName) ->
    gen_server:cast(?SERVER , {start_task, TaskName}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
    {ok , Pid :: pid()} | ignore | {error , Reason :: term()}).
start_link() ->
    gen_server:start_link({local , ?SERVER} , ?MODULE , [] , []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
    {ok , State :: #state{}} | {ok , State :: #state{} , timeout() | hibernate} |
    {stop , Reason :: term()} | ignore).
init([]) ->
    logger:log(info, "Initializing task worker module"),
    _Tab = achlys_util:create_table(task_history),
    erlang:send_after(?TEN, ?SERVER, periodical_check),
    {ok , #state{
        tasks = dict:new()
        , available_slots = 5
    }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term() , From :: {pid() , Tag :: term()} ,
                  State :: #state{}) ->
                     {reply , Reply :: term() , NewState :: #state{}} |
                     {reply , Reply :: term() , NewState :: #state{} , timeout() | hibernate} |
                     {noreply , NewState :: #state{}} |
                     {noreply , NewState :: #state{} , timeout() | hibernate} |
                     {stop , Reason :: term() , Reply :: term() , NewState :: #state{}} |
                     {stop , Reason :: term() , NewState :: #state{}}).
handle_call(_Request , _From , State) ->
    {reply , ok , State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term() , State :: #state{}) ->
    {noreply , NewState :: #state{}} |
    {noreply , NewState :: #state{} , timeout() | hibernate} |
    {stop , Reason :: term() , NewState :: #state{}}).
handle_cast({start_task, TaskName} , State) ->
    %% TODO : basic approach for generic task execution can be done using :
    %% List = achlys:get_all_tasks(),
    %% T = hd([ X || X <- List, #{name := N} = X, N =:= TaskName ]),
    %% #{function := Fun, targets := _Targets} = T,
    %% % TODO : Check if part of destination set
    %% Result = Fun(),
    {noreply , State};

handle_cast(_Request , State) ->
    {noreply , State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term() , State :: #state{}) ->
    {noreply , NewState :: #state{}} |
    {noreply , NewState :: #state{} , timeout() | hibernate} |
    {stop , Reason :: term() , NewState :: #state{}}).
handle_info(periodical_check , State) ->
    Tasks = achlys_util:query(?TASKS),
    logger:log(info, "Task list : ~p", [Tasks]),

    L = [ {H, spawn_task(T)} || {T, H} <- Tasks
        , permanent_execution(T, H) =:= true
        , dict:is_key(H, State#state.tasks) =:= false ],

    logger:log(info, "New tasks : ~p", [L]),

    NewDict = lists:foldl(fun
        (Elem, AccIn) ->
            {H, Proc} = Elem,
            dict:store(H, Proc, AccIn)
    end, State#state.tasks, L),

    logger:log(info, "New dict : ~p", [NewDict]),

    erlang:send_after(?HMIN, ?SERVER, periodical_check),
    {noreply , State#state{tasks = NewDict}, hibernate};

%%--------------------------------------------------------------------
handle_info({'DOWN', Ref, process, Pid, Info} , State) ->
    
    logger:log(info, "Task finished : ~p", [Ref]),
    
    NewDict = dict:filter(fun
        (K, V) ->
            case V =/= {Pid, Ref} of
                true ->
                    true;
                false ->
                    case ets:insert_new(task_history, {K, V}) of
                        true  ->
                            false;
                        false ->
                            logger:log(warning, "ets:insert_new failed for entry : ~p", [{K, V}]),
                            false
                    end
            end
    end, State#state.tasks),

    true = erlang:demonitor(Ref, [flush]),

    logger:log(info, "Task demonitored : ~p", [Ref]),
    logger:log(info, "New dict : ~p", [NewDict]),
    logger:log(info, "New Task history : ~p", [ets:match(task_history, '$1')]),
    
    {noreply , State#state{tasks = NewDict}};

%%--------------------------------------------------------------------
handle_info(_Info , State) ->
    {noreply , State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown , term()} | term()) ,
                State :: #state{}) -> term()).
terminate(_Reason , _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down , term()} , State :: #state{} ,
                  Extra :: term()) ->
                     {ok , NewState :: #state{}} | {error , Reason :: term()}).
code_change(_OldVsn , State , _Extra) ->
    {ok , State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
spawn_task(Task) -> 
    logger:log(info, "Spawning task : ~p", [Task]),
    F = get_task_function(Task),
    logger:log(info, "Func : ~p", [F]),
    
    {Pid, Ref} = erlang:spawn_opt(F, [monitor
        , {max_heap_size, #{size => 16384
            , kill => true
            , error_logger => false}}
        , {message_queue_data, off_heap}
        , {fullsweep_after, 0}]),
    
    logger:log(info, "Spawned task ~p ", [Ref]),
    {Pid, Ref}.

%%--------------------------------------------------------------------
%% @private
get_task_function(Task) ->
    #{function := F} = Task,
    F.

%%--------------------------------------------------------------------
%% @private
permanent_execution(T, H) ->
    #{execution_type := ExecType} = T,
    case ExecType of
        ?PERMANENT_TASK ->
            true;
        ?SINGLE_EXECUTION_TASK ->
            not ets:member(task_history, H);
        _ ->
            false
    end.