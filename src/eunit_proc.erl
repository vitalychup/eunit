%% ``The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved via the world wide web at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% The Initial Developer of the Original Code is Richard Carlsson.''
%%
%% File: eunit_proc.erl
%%
%% $Id:$ 
%%
%% @author Richard Carlsson <richardc@it.uu.se>
%% @copyright 2006 Richard Carlsson
%% @private
%% @see eunit
%% @doc Test runner process tree functions

-module(eunit_proc).

-include("eunit.hrl").
-include("eunit_internal.hrl").

-export([start/4]).


-record(procstate, {ref, id, super, insulator, parent, order}).


%% spawns test process and returns the process Pid; sends {done,
%% Reference, Pid} to caller when finished

start(Tests, Reference, Super, Order) ->
    spawn_tester(Tests, init_procstate(Reference, Super, Order)).

init_procstate(Reference, Super, Order) ->
    #procstate{ref = Reference, id = [], super = Super, order = Order}.


%% ---------------------------------------------------------------------
%% Process tree primitives

%% A "task" consists of an insulator process and a child process which
%% handles the actual work. When the child terminates, the insulator
%% process sends {done, Reference, self()} to the process which started
%% the task (the "parent"). The child process is given a State record
%% which contains the process id:s of the parent, the insulator, and the
%% supervisor.

%% @spec ((#procstate{}) -> () -> term(), #procstate{}) -> pid()

start_task(Fun, St0) ->
    St = St0#procstate{parent = self()},
    %% (note: the link here is mainly to propagate signals *downwards*,
    %% so that the insulator can detect if the process that started the
    %% task dies before the task is done)
    spawn_link(fun () -> insulator_process(Fun, St) end).

%% Simple, failure-proof insulator process
%% (This is cleaner than temporarily setting up the caller to trap
%% signals, and does not affect the caller's mailbox or other state.)

%% @spec (Fun::() -> term(), St::#procstate{}) -> ok

insulator_process(Fun, St0) ->
    process_flag(trap_exit, true),
    St = St0#procstate{insulator = self()},
    Child = spawn_link(fun () -> child_process(Fun(St), St) end),
    Parent = St#procstate.parent,
    insulator_wait(Child, Parent, St).

%% Normally, child processes exit with the reason 'normal' even if the
%% executed tests failed (by throwing exceptions), since the tests are
%% executed within a try-block. Child processes can terminate abnormally
%% by the following reasons:
%%   1) an error in the processing of the test descriptors (a malformed
%%      descriptor, failure in a setup, cleanup or initialization, a
%%      missing module or function, or a failing generator function);
%%   2) an internal error in the test running framework itself;
%%   3) receiving a non-trapped error signal as a consequence of running
%%      test code.
%% Those under point 1 are "expected errors", handled specially in the
%% protocol, while the other two are unexpected errors. (Since alt. 3
%% implies that the test neither reported success nor failure, it can
%% never be considered "proper" behaviour of a test.) Abnormal
%% termination is reported to the supervisor process but otherwise does
%% not affect the insulator compared to normal termination. Child
%% processes can also be killed abruptly by their insulators, in case of
%% a timeout or if a parent process dies.

insulator_wait(Child, Parent, St) ->
    receive
	{progress, Child, Id, Msg} ->
	    status_message(Id, {progress, Msg}, St),
	    insulator_wait(Child, Parent, St);
	{abort, Child, Id, Reason} ->
	    exit_message(Id, {abort, Reason}, St),
	    %% no need to wait for the {'EXIT',Child,_} message
	    terminate_insulator(St);
	{timeout, Child, Id} ->
	    exit_message(Id, timeout, St),
	    kill_task(Child, St);
	{'EXIT', Child, normal} ->
	    terminate_insulator(St);
	{'EXIT', Child, Reason} ->
	    exit_message(St#procstate.id, {exit, Reason}, St),
	    terminate_insulator(St);
	{'EXIT', Parent, _} ->
	    %% make sure child processes are cleaned up recursively
	    kill_task(Child, St)
    end.

status_message(Id, Msg, St) ->
    St#procstate.super ! {status, Id, Msg}.

%% send status messages for the Id of the "causing" item, and also for
%% the Id of the insulator itself, if they are different

%% TODO: this function naming is not very good. too many similar names.
exit_message(Id, Msg0, St) ->
    %% note that the most specific Id is always sent first
    Msg = {cancel, Msg0},
    status_message(Id, Msg, St),
    case St#procstate.id of
	Id -> ok;
	Id1 -> status_message(Id1, Msg, St)
    end.

%% Unlinking before exit avoids polluting the parent process with exit
%% signals from the insulator. The child process is already dead here.

terminate_insulator(St) ->
    %% messaging/unlinking is ok even if the parent is already dead
    Parent = St#procstate.parent,
    Parent ! {done, St#procstate.ref, self()},
    unlink(Parent),
    exit(normal).

kill_task(Child, St) ->
    exit(Child, kill),
    terminate_insulator(St).

%% Note that child processes send all messages via the insulator to
%% ensure proper sequencing with timeouts and exit signals.

abort_message(Reason, St) ->
    St#procstate.insulator ! {abort, self(), St#procstate.id, Reason}.

progress_message(Msg, St) ->
    St#procstate.insulator ! {progress, self(), St#procstate.id, Msg}.

set_timeout(Time, St) ->
    erlang:send_after(Time, St#procstate.insulator,
		      {timeout, self(), St#procstate.id}).

clear_timeout(Ref) ->
    erlang:cancel_timer(Ref).

with_timeout(undefined, Default, F, St) ->
    with_timeout(Default, F, St);
with_timeout(Time, _Default, F, St) ->
    with_timeout(Time, F, St).

with_timeout(infinity, F, _St) ->
    %% don't start timers unnecessarily
    {T0, _} = statistics(wall_clock),
    Value = F(),
    {T1, _} = statistics(wall_clock),
    {Value, T1 - T0};
with_timeout(Time, F, St) when is_integer(Time), Time >= 0 ->
    Ref = set_timeout(Time, St),
    {T0, _} = statistics(wall_clock),
    try F() of
	Value ->
	    %% we could also read the timer, but this is simpler
	    {T1, _} = statistics(wall_clock),
	    {Value, T1 - T0}
    after
	clear_timeout(Ref)
    end.

%% The normal behaviour of a child process is to trap exit signals. This
%% makes it easier to write tests that spawn off separate (linked)
%% processes and test whether they terminate as expected. The testing
%% framework is not dependent on this, however, so the test code is
%% allowed to disable signal trapping as it pleases.

%% @spec (() -> term(), #procstate{}) -> ok

child_process(Fun, St) ->
    process_flag(trap_exit, true),
    try Fun() of
	_ -> ok
    catch
	{abort, Reason} ->
	    abort_message(Reason, St),
	    exit(aborted)
    end.

%% @throws abortException()
%% @type abortException() = {abort, Reason::term()}

abort_task(Reason) ->
    throw({abort, Reason}).

%% Typically, the process that executes this code is trapping signals,
%% but it might not be - it is outside of our control, since test code
%% could turn off trapping. That is why the insulator process of a task
%% must be guaranteed to always send a reply before it terminates.
%%
%% The unique reference guarantees that we don't extract any message
%% from the mailbox unless it belongs to the test framework (and not to
%% the running tests). When the wait-loop terminates, no such message
%% should remain in the mailbox.

wait_for_task(Pid, St) ->
    wait_for_tasks(sets:from_list([Pid]), St).

wait_for_tasks(PidSet, St) ->
    case sets:size(PidSet) of
	0 ->
	    ok;
	_ ->
	    %% (note that when we receive this message for some task, we
	    %% are guaranteed that the insulator process of the task has
	    %% already informed the supervisor about any anomalies)
	    Reference = St#procstate.ref,
	    receive
		{done, Reference, Pid} ->
		    %% (if Pid is not in the set, del_element has no
		    %% effect, so this is always safe)
		    Rest = sets:del_element(Pid, PidSet),
		    wait_for_tasks(Rest, St)
	    end
    end.


%% ---------------------------------------------------------------------
%% Separate testing process

spawn_tester(T, St0) ->
    Fun = fun (St) ->
		  fun () -> tests(T, St) end
	  end,
    start_task(Fun, St0).

%% @throws abortException()

tests(T, St) ->
    I = eunit_data:iter_init(T, St#procstate.id),
    case St#procstate.order of
	true -> tests_inorder(I, St);
	false -> tests_inparallel(I, St)
    end.

set_id(I, St) ->
    St#procstate{id = eunit_data:iter_id(I)}.

%% @throws abortException()

tests_inorder(I, St) ->
    case get_next_item(I) of
	{T, I1} ->
	    handle_item(T, set_id(I1, St)),
	    tests_inorder(I1, St);
	none ->
	    ok
    end.

%% @throws abortException()

tests_inparallel(I, St) ->
    tests_inparallel(I, St, sets:new()).

tests_inparallel(I, St, Children) ->
    case get_next_item(I) of
	{T, I1} ->
	    Child = spawn_item(T, set_id(I1, St)),
	    tests_inparallel(I1, St, sets:add_element(Child, Children));
	none ->
	    wait_for_tasks(Children, St),
	    ok
    end.

%% @throws abortException()

spawn_item(T, St0) ->
    Fun = fun (St) ->
		  fun () -> handle_item(T, St) end
	  end,
    start_task(Fun, St0).

get_next_item(I) ->
    eunit_data:iter_next(I, fun abort_task/1).

%% @throws abortException()

handle_item(T, St) ->
    case T of
	#test{} -> handle_test(T, St);
	#group{} -> handle_group(T, St)
    end.

handle_test(T, St) ->
    progress_message({'begin', test}, St),
    {Status, Time} = with_timeout(T#test.timeout, ?DEFAULT_TEST_TIMEOUT,
				  fun () -> run_test(T) end, St),
    progress_message({'end', {Status, Time}}, St),
    ok.

%% @spec (#test{}) -> {ok, Value} | {error, eunit_lib:exception()}
%% @throws eunit_test:wrapperError()

run_test(#test{f = F}) ->
    try eunit_test:run_testfun(F) of
	{ok, _Value} ->
	    %% just throw away the return value
	    ok;
	{error, Exception} ->
	    {error, Exception}
    catch
	R = {module_not_found, _M} ->
	    {skipped, R};
	  R = {no_such_function, _MFA} ->
	    {skipped, R}
    end.

set_group_order(#group{order = undefined}, St) ->
    St;
set_group_order(#group{order = Order}, St) ->
    St#procstate{order = Order}.

handle_group(T, St0) ->
    St = set_group_order(T, St0),
    Timeout = T#group.timeout,
    case T#group.spawn of
	true ->
	    Child = spawn_group(T, Timeout, St),
	    wait_for_task(Child, St);
	_ ->
	    subtests(T, fun (T) -> group(T, Timeout, St) end)
    end.

spawn_group(T, Timeout, St0) ->
    Fun = fun (St) ->
		  fun () ->
			  subtests(T, fun (T) ->
					      group(T, Timeout, St)
				      end)
		  end
	  end,
    start_task(Fun, St0).

group(T, Timeout, St) ->
    progress_message({'begin', group}, St),
    {Value, Time} = with_timeout(Timeout, ?DEFAULT_GROUP_TIMEOUT,
				 fun () -> tests(T, St) end, St),
    progress_message({'end', Time}, St),
    Value.


%% @throws abortException()

subtests(#group{context = undefined, tests = T}, F) ->
    F(T);
subtests(#group{context = #context{} = C, tests = I}, F) ->
    try
	eunit_data:enter_context(C, I, F)
    catch
	R = setup_failed ->
	    abort_task(R);
	  R = cleanup_failed ->
	    abort_task(R);
	  R = instantiation_failed ->
	    abort_task(R)
    end.
