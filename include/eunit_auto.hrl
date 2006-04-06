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
%% File: eunit_auto.hrl
%%
%% $Id:$ 
%%
%% Copyright (C) 2006 Richard Carlsson

-ifndef(EUNIT_AUTO_HRL).
-define(EUNIT_AUTO_HRL, true).

%% Since this file is normally included with include_lib, it must in its
%% turn use include_lib to read any other header files, at least until
%% the epp include_lib behaviour is fixed.
-include_lib("eunit/include/eunit.hrl").
%%-include("eunit.hrl").

-ifndef(NOTEST).
-compile({parse_transform, eunit_autoexport}).
-endif.

-endif. % EUNIT_AUTO_HRL
