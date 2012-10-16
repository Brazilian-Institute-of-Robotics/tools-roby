$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))

require 'test_bgl'
require 'test_relations'
require 'test_event'
require 'test_task'
require 'state/test_goal_model'
require 'state/test_open_struct'
require 'state/test_state_events'
require 'state/test_state_model'
require 'state/test_state_space'
require 'state/test_task'
require 'test_event_constraints'

require 'test_execution_engine'
require 'test_exceptions'

require 'test_plan'
require 'test_query'
require 'test_transactions'
require 'test_transactions_proxy'

require 'tasks/test_thread_task'
require 'tasks/test_external_process'

require 'schedulers/test_basic'
require 'schedulers/test_temporal'

require 'test_testcase'

require 'suite_planning'
require 'suite_relations'

require 'test_interface'
require 'test_log'

require 'test_task_scripting'
require 'test_task_statemachine'

