$LOAD_PATH.unshift File.expand_path(File.join('..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/tasks/simple'
require 'roby/test/tasks/empty_task'
require 'roby/tasks/simple'
require 'flexmock/test_unit'

class TC_Task < Test::Unit::TestCase 
    include Roby::Test
    include Roby::Test::Assertions
    def setup
        super
        Roby.app.filter_backtraces = false
    end

    def test_model_tag
        tag1 = TaskModelTag.new { argument :model_tag_1 }
	assert(tag1.const_defined?(:ClassExtension))
	assert(tag1::ClassExtension.method_defined?(:argument))

	tag2 = TaskModelTag.new do
            include tag1
            argument :model_tag_2
        end
	assert(tag2 < tag1)
	assert(tag2.const_defined?(:ClassExtension))
	assert(tag2::ClassExtension.method_defined?(:argument))

	task = Class.new(Task) do
	    include tag2
	    argument :task_tag
	end
	assert_equal([:task_tag, :model_tag_2, :model_tag_1].to_set, task.arguments.to_set)
    end

    def test_abstract
        assert Roby::Task.abstract?

        model = Class.new(Roby::Task)
        assert !model.abstract?

        abstract_model = Class.new(model) do
            abstract
        end
        assert abstract_model.abstract?

        plan.add(task = model.new)
        assert !task.abstract?
        assert task.executable?
        task.abstract = true
        assert task.abstract?
        assert !task.executable?

        plan.add(task = abstract_model.new)
        assert task.abstract?
        assert !task.executable?
        task.abstract = false
        assert !task.abstract?
        assert task.executable?
    end

    def test_arguments_declaration
	model = Class.new(Task) { argument :from; argument :to }
	assert_equal([], Task.arguments.to_a)
	assert_equal([:from, :to].to_value_set, model.arguments.to_value_set)
    end

    def test_arguments_initialization
	model = Class.new(Task) { argument :arg; argument :to }
	plan.add(task = model.new(:arg => 'B'))
	assert_equal({:arg => 'B'}, task.arguments)
        assert_equal('B', task.arg)
        assert_equal(nil, task.to)
    end

    def test_arguments_initialization_uses_assignation_operator
	model = Class.new(Task) do
            argument :arg; argument :to

            undef_method :arg=
            def arg=(value)
                arguments[:assigned] = true
                arguments[:arg] = value
            end
        end

	plan.add(task = model.new(:arg => 'B'))
	assert_equal({:arg => 'B', :assigned => true}, task.arguments)
    end

    def test_arguments_assignation
	model = Class.new(Task) { argument :arg }
	plan.add(task = model.new)
	task.arguments[:arg] = 'A'
        assert_equal('A', task.arg)
        assert_equal({ :arg => 'A' }, task.arguments)
    end
    
    def test_arguments_assignation_operator
	model = Class.new(Task) { argument :arg }
	plan.add(task = model.new)
        task.arg = 'B'
        assert_equal('B', task.arg)
        assert_equal({ :arg => 'B' }, task.arguments)
    end

    def test_meaningful_arguments
	model = Class.new(Task) { argument :arg }
	plan.add(task = model.new(:arg => 'B', :useless => 'bla'))
	assert_equal({:arg => 'B', :useless => 'bla'}, task.arguments)
	assert_equal({:arg => 'B'}, task.meaningful_arguments)
    end

    def test_arguments_cannot_override
	model = Class.new(Task) { argument :arg }
	plan.add(task = model.new(:arg => 'B', :useless => 'bla'))
	assert_raises(ArgumentError) { task.arg = 10 }

        # But we can override non-meaningful arguments
	task.arguments[:bar] = 42
	assert_nothing_raised { task.arguments[:bar] = 43 }
    end

    def test_arguments_partially_instanciated
	model = Class.new(Task) { argument :arg0; argument :arg1 }
	plan.add(task = model.new(:arg0 => 'B', :useless => 'bla'))
	assert(task.partially_instanciated?)
        task.arg1 = 'C'
	assert(!task.partially_instanciated?)
    end

    def test_command_block
	FlexMock.use do |mock|
	    model = Class.new(Tasks::Simple) do 
		event :start do |context|
		    mock.start(self, context)
		    emit :start
		end
	    end
	    plan.add_mission(task = model.new)
	    mock.should_receive(:start).once.with(task, [42])
	    task.start!(42)
	end
    end

    def test_command_inheritance
        FlexMock.use do |mock|
            parent_m = Class.new(Tasks::Simple) do
                event :start do |context|
                    mock.parent_started(self, context)
                    emit :start
                end
            end

            child_m = Class.new(parent_m) do
                event :start do |context|
                    mock.child_started(self, context.first)
                    super(context.first / 2)
                end
            end

            plan.add_mission(task = child_m.new)
            mock.should_receive(:parent_started).once.with(task, 21)
            mock.should_receive(:child_started).once.with(task, 42)
            task.start!(42)
        end
    end

    def assert_task_relation_set(task, relation, expected)
        plan.add(task)
        task.each_event do |from|
            task.each_event do |to|
                next if from == to
                exp = expected[from.symbol]
                if exp == to.symbol || (exp.respond_to?(:include?) && exp.include?(to.symbol))
                    assert from.child_object?(to, relation), "expected relation #{from} => #{to} in #{relation} is missing"
                else
                    assert !from.child_object?(to, relation), "unexpected relation #{from} => #{to} found in #{relation}"
                end
            end
        end
    end

    def do_test_instantiate_model_relations(method, relation, additional_links = Hash.new)
	klass = Class.new(Roby::Test::Tasks::Simple) do
            4.times { |i| event "e#{i + 1}", :command => true }
            send(method, :e1 => [:e2, :e3], :e4 => :stop)
	end

        plan.add(task = klass.new)
        expected_links = Hash[:e1 => [:e2, :e3], :e4 => :stop]
        
        assert_task_relation_set task, relation, expected_links.merge(additional_links)
    end
    def test_instantiate_model_signals
        do_test_instantiate_model_relations(:signal, EventStructure::Signal, :internal_error => :stop)
    end
    def test_instantiate_deprecated_model_on
        deprecated_feature do
            do_test_instantiate_model_relations(:on, EventStructure::Signal, :internal_error => :stop)
        end
    end
    def test_instantiate_model_forward
        do_test_instantiate_model_relations(:forward, EventStructure::Forwarding,
                           :success => :stop, :aborted => :failed, :failed => :stop)
    end
    def test_instantiate_model_causal_links
        do_test_instantiate_model_relations(:causal_link, EventStructure::CausalLink,
                           :internal_error => :stop, :success => :stop, :aborted => :failed, :failed => :stop)
    end

    
    def do_test_inherit_model_relations(method, relation, additional_links = Hash.new)
	base = Class.new(Roby::Test::Tasks::Simple) do
            4.times { |i| event "e#{i + 1}", :command => true }
            send(method, :e1 => [:e2, :e3])
	end
        subclass = Class.new(base) do
            send(method, :e4 => :stop)
        end

        task = base.new
        assert_task_relation_set task, relation,
            Hash[:e1 => [:e2, :e3]].merge(additional_links)

        task = subclass.new
        assert_task_relation_set task, relation,
            Hash[:e1 => [:e2, :e3], :e4 => :stop].merge(additional_links)
    end
    def test_inherit_model_signals
        do_test_inherit_model_relations(:signal, EventStructure::Signal, :internal_error => :stop)
    end
    def test_inherit_deprecated_model_on
        deprecated_feature do
            do_test_inherit_model_relations(:on, EventStructure::Signal, :internal_error => :stop)
        end
    end
    def test_inherit_model_forward
        do_test_inherit_model_relations(:forward, EventStructure::Forwarding,
                           :success => :stop, :aborted => :failed, :failed => :stop)
    end
    def test_inherit_model_causal_links
        do_test_inherit_model_relations(:causal_link, EventStructure::CausalLink,
                           :internal_error => :stop, :success => :stop, :aborted => :failed, :failed => :stop)
    end

    # Test the behaviour of Task#on, and event propagation inside a task
    def test_instance_event_handlers
	plan.add(t1 = Tasks::Simple.new)
	assert_raises(ArgumentError) { t1.on(:start) }
	
	plan.add(task = Tasks::Simple.new)
	FlexMock.use do |mock|
	    task.on(:start)   { |event| mock.started(event.context) }
	    task.on(:start)   { |event| task.emit(:success, *event.context) }
	    task.on(:success) { |event| mock.success(event.context) }
	    task.on(:stop)    { |event| mock.stopped(event.context) }
	    mock.should_receive(:started).once.with([42]).ordered
	    mock.should_receive(:success).once.with([42]).ordered
	    mock.should_receive(:stopped).once.with([42]).ordered
	    task.start!(42)
	end
        assert(task.finished?)
	event_history = task.history.map { |ev| ev.generator }
	assert_equal([task.event(:start), task.event(:success), task.event(:stop)], event_history)
    end

    def test_instance_signals
	FlexMock.use do |mock|
	    t1, t2 = prepare_plan :add => 3, :model => Tasks::Simple
            t1.signals(:start, t2, :start)

	    t2.on(:start) { |ev| mock.start }
            mock.should_receive(:start).once
	    t1.start!
	end
    end

    def test_instance_signals_plain_events
	t = prepare_plan :missions => 1, :model => Tasks::Simple
	e = EventGenerator.new(true)
	t.signals(:start, e)
	t.start!
	assert(e.happened?)
    end

    def test_model_forwardings
	model = Class.new(Tasks::Simple) do
	    forward :start => :failed
	end
	assert_equal({ :start => [:failed, :stop].to_value_set }, model.forwarding_sets)
	assert_equal({}, Tasks::Simple.signal_sets)

	assert_equal([:failed, :stop].to_value_set, model.forwardings(:start))
	assert_equal([:stop].to_value_set,          model.forwardings(:failed))
	assert_equal([:stop].to_value_set,          model.enum_for(:each_forwarding, :failed).to_value_set)

        plan.add(task = model.new)
        task.start!

	# Make sure the model-level relation is not applied to parent models
	plan.add(task = Tasks::Simple.new)
	task.start!
	assert(!task.failed?)
    end

    def test_model_event_handlers
	model = Class.new(Tasks::Simple)
        assert_raises(ArgumentError) { model.on(:start) { || } }
        assert_raises(ArgumentError) { model.on(:start) { |a, b| } }

	FlexMock.use do |mock|
	    model.on :start do |ev|
		mock.start_called(self)
	    end
	    plan.add(task = model.new)
	    mock.should_receive(:start_called).with(task).once
	    task.start!

            # Make sure the model-level handler is not applied to parent models
            plan.add(task = Tasks::Simple.new)
            task.start!
            assert(!task.failed?)
	end
    end

    def test_instance_forward_to
	FlexMock.use do |mock|
	    t1, t2 = prepare_plan :missions => 2, :model => Tasks::Simple
	    t1.forward_to(:start, t2, :start)
	    t2.on(:start) { |context| mock.start }

	    mock.should_receive(:start).once
	    t1.start!
	end
    end

    def test_instance_forward_to_plain_events
	FlexMock.use do |mock|
	    t1 = prepare_plan :missions => 1, :model => Tasks::Simple
	    ev = EventGenerator.new do 
		mock.called
		ev.emit
	    end
	    ev.on { |event| mock.emitted }
	    t1.forward_to(:start, ev)

	    mock.should_receive(:called).never
	    mock.should_receive(:emitted).once
	    t1.start!
	end
    end

    def test_terminal_option
	klass = Class.new(Task) do
            event :terminal, :terminal => true
        end
        assert klass.event_model(:terminal).terminal?
        plan.add(task = klass.new)
        assert task.event(:terminal).terminal?
        assert task.event(:terminal).child_object?(task.event(:stop), EventStructure::Forwarding)
    end

    ASSERT_EVENT_ALL_PREDICATES = [:terminal?, :failure?, :success?]
    ASSERT_EVENT_PREDICATES = {
        :normal   => [],
        :stop     => [:terminal?],
        :failed   => [:terminal?, :failure?],
        :success  => [:terminal?, :success?]
    }

    def assert_model_event_flag(model, event_name, model_flag)
        if model_flag != :normal
            assert model.event_model(event_name).terminal?, "#{model}.#{event_name}.terminal? returned false"
        else
            assert !model.event_model(event_name).terminal?, "#{model}.#{event_name}.terminal? returned true"
        end
    end

    def assert_event_flag(task, event_name, instance_flag, model_flag)
        ASSERT_EVENT_PREDICATES[instance_flag].each do |pred|
            assert task.event(event_name).send(pred), "#{task}.#{event_name}.#{pred} returned false"
        end
        (ASSERT_EVENT_ALL_PREDICATES - ASSERT_EVENT_PREDICATES[instance_flag]).each do |pred|
            assert !task.event(event_name).send(pred), "#{task}.#{event_name}.#{pred} returned true"
        end
        assert_model_event_flag(task, event_name, model_flag)
    end

    def test_terminal_forward_stop(target_event = :stop)
	klass = Class.new(Task) do
	    event :direct

            event :indirect
            event :intermediate
	end
        plan.add(task = klass.new)
        task.forward_to :direct, task, target_event
        task.forward_to :indirect, task, :intermediate
        task.forward_to :intermediate, task, target_event
        assert_event_flag(task, :direct, target_event, :normal)
        assert_event_flag(task, :indirect, target_event, :normal)
    end
    def test_terminal_forward_success; test_terminal_forward_stop(:success) end
    def test_terminal_forward_failed; test_terminal_forward_stop(:failed) end

    def test_terminal_forward_stop_in_model(target_event = :stop)
	klass = Class.new(Task) do
	    event :direct
            forward :direct => target_event

            event :indirect
            event :intermediate
            forward :indirect => :intermediate
            forward :intermediate => target_event
	end
        assert_model_event_flag(klass, :direct, target_event)
        assert_model_event_flag(klass, :indirect, target_event)
        plan.add(task = klass.new)
        assert_event_flag(task, :direct, target_event, target_event)
        assert_event_flag(task, :indirect, target_event, target_event)
    end
    def test_terminal_forward_success_in_model; test_terminal_forward_stop_in_model(:success) end
    def test_terminal_forward_failed_in_model; test_terminal_forward_stop_in_model(:failed) end

    def test_terminal_signal_stop(target_event = :stop)
	klass = Class.new(Task) do
	    event :direct

            event :indirect
            event :intermediate, :controlable => true
            event target_event, :controlable => true, :terminal => true
	end
        plan.add(task = klass.new)
        task.signals :direct, task, target_event
        task.signals :indirect, task, :intermediate
        task.signals :intermediate, task, target_event
        assert_event_flag(task, :direct, target_event, :normal)
        assert_event_flag(task, :indirect, target_event, :normal)
    end
    def test_terminal_signal_success; test_terminal_signal_stop(:success) end
    def test_terminal_signal_failed; test_terminal_signal_stop(:failed) end

    def test_terminal_signal_stop_in_model(target_event = :stop)
	klass = Class.new(Task) do
	    event :direct

            event :indirect
            event :intermediate, :controlable => true
            event target_event, :controlable => true, :terminal => true

            signal :direct => target_event
            signal :indirect => :intermediate
            signal :intermediate => target_event
	end
        assert_model_event_flag(klass, :direct, target_event)
        assert_model_event_flag(klass, :indirect, target_event)
        plan.add(task = klass.new)
        assert_event_flag(task, :direct, target_event, target_event)
        assert_event_flag(task, :indirect, target_event, target_event)
    end
    def test_terminal_signal_success_in_model; test_terminal_signal_stop_in_model(:success) end
    def test_terminal_signal_failed_in_model; test_terminal_signal_stop_in_model(:failed) end

    def test_terminal_alternate_stop(target_event = :stop)
	klass = Class.new(Task) do
            event :forward_first
            event :intermediate_signal
            event target_event, :controlable => true, :terminal => true

            event :signal_first
            event :intermediate_forward, :controlable => true
	end
        assert_model_event_flag(klass, :signal_first, :normal)
        assert_model_event_flag(klass, :forward_first, :normal)
        plan.add(task = klass.new)

        task.forward_to :forward_first, task, :intermediate_signal
        task.signals :intermediate_signal, task, target_event
        task.signals :signal_first, task, :intermediate_forward
        task.forward_to :intermediate_forward, task, target_event
        assert_event_flag(task, :signal_first, target_event, :normal)
        assert_event_flag(task, :forward_first, target_event, :normal)
    end
    def test_terminal_alternate_success; test_terminal_signal_stop(:success) end
    def test_terminal_alternate_failed; test_terminal_signal_stop(:failed) end

    def test_terminal_alternate_stop_in_model(target_event = :stop)
	klass = Class.new(Task) do
            event :forward_first
            event :intermediate_signal
            event target_event, :controlable => true, :terminal => true

            event :signal_first
            event :intermediate_forward, :controlable => true

            forward :forward_first => :intermediate_signal
            signal  :intermediate_signal => target_event
            signal :signal_first => :intermediate_forward
            forward :intermediate_forward => target_event
	end
        assert_model_event_flag(klass, :signal_first, target_event)
        assert_model_event_flag(klass, :forward_first, target_event)
        plan.add(task = klass.new)
        assert_event_flag(task, :signal_first, target_event, target_event)
        assert_event_flag(task, :forward_first, target_event, target_event)
    end
    def test_terminal_alternate_success_in_model; test_terminal_signal_stop_in_model(:success) end
    def test_terminal_alternate_failed_in_model; test_terminal_signal_stop_in_model(:failed) end

    def test_should_not_establish_signal_from_terminal_to_non_terminal
	klass = Class.new(Task) do
	    event :terminal, :terminal => true
            event :intermediate
	end
        assert_raises(ArgumentError) { klass.forward :terminal => :intermediate }
        klass.new
    end

    # Tests Task::event
    def test_event_declaration
	klass = Class.new(Task) do
	    def ev_not_controlable;     end
	    def ev_method(event = :ev_method); :ev_method if event == :ev_redirected end

	    event :ev_contingent
	    event :ev_controlable do |*events|
                :ev_controlable
            end

	    event :ev_not_controlable
	    event :ev_redirected, :command => lambda { |task, event, *args| task.ev_method(event) }
	end

	klass.event :ev_terminal, :terminal => true, :command => true

	plan.add(task = klass.new)
	assert_respond_to(task, :start!)
        assert_respond_to(task, :start?)

        # Test modifications to the class hierarchy
        my_event = nil
        assert_nothing_raised   { my_event = klass.const_get(:EvContingent) }
        assert_raise(NameError) { klass.superclass.const_get(:EvContingent) }
        assert_equal( TaskEvent, my_event.superclass )
        assert_equal( :ev_contingent, my_event.symbol )
        assert( klass.has_event?(:ev_contingent) )
    
        assert_nothing_raised   { my_event = klass.const_get(:EvTerminal) }
        assert_equal( :ev_terminal, my_event.symbol )

        # Check properties on EvContingent
        assert( !klass::EvContingent.respond_to?(:call) )
        assert( !klass::EvContingent.controlable? )
        assert( !klass::EvContingent.terminal? )

        # Check properties on EvControlable
        assert( klass::EvControlable.controlable? )
        assert( klass::EvControlable.respond_to?(:call) )
        event = klass::EvControlable.new(task, task.event(:ev_controlable), 0, nil)
        assert_equal(:ev_controlable, klass::EvControlable.call(task, :ev_controlable))

        # Check Event.terminal? if :terminal => true
        assert( klass::EvTerminal.terminal? )

        # Check :controlable => [proc] behaviour
        assert( klass::EvRedirected.controlable? )
        
        # Check that :command => false disables controlable?
        assert( !klass::EvNotControlable.controlable? )

        # Check validation of options[:command]
        assert_raise(ArgumentError) { klass.event :try_event, :command => "bla" }

        plan.add(task = EmptyTask.new)
	start_event = task.event(:start)

        assert_equal(start_event, task.event(:start))
        assert_equal([], start_event.handlers)
	# Note that the start => stop forwarding is added because 'start' is
	# detected as terminal in the EmptyTask model
        assert_equal([task.event(:stop), task.event(:success)].to_set, start_event.enum_for(:each_forwarding).to_set)
        start_model = task.event_model(:start)
        assert_equal(start_model, start_event.event_model)
        assert_equal([:stop, :success].to_set, task.enum_for(:each_forwarding, :start).to_set)
    end
    def test_status
	task = Class.new(Roby::Task) do
	    event :start do |context|
	    end
	    event :failed, :terminal => true do |context|
	    end
	    event :stop do |context|
		failed!
	    end
	end.new
	plan.add(task)

	assert(task.pending?)
	assert(!task.starting?)
	assert(!task.running?)
	assert(!task.success?)
	assert(!task.failed?)
	assert(!task.finishing?)
	assert(!task.finished?)

	task.start!
	assert(!task.pending?)
	assert(task.starting?)
	assert(!task.running?)
	assert(!task.success?)
	assert(!task.failed?)
	assert(!task.finishing?)
	assert(!task.finished?)

	task.emit(:start)
	assert(!task.pending?)
	assert(!task.starting?)
	assert(task.running?)
	assert(!task.success?)
	assert(!task.failed?)
	assert(!task.finishing?)
	assert(!task.finished?)

	task.stop!
	assert(!task.pending?)
	assert(!task.starting?)
	assert(task.running?)
	assert(!task.success?)
	assert(!task.failed?)
	assert(task.finishing?)
	assert(!task.finished?)

	task.emit(:failed)
	assert(!task.pending?)
	assert(!task.starting?)
	assert(!task.running?)
	assert(!task.success?)
	assert(task.failed?)
	assert(!task.finishing?)
	assert(task.finished?)
    end

    def test_status_precisely
        status_flags = [:pending?, :starting?, :started?, :running?, :finishing?, :finished?, :success?]
        expected_status = lambda do |true_flags|
            result = true_flags.dup
            status_flags.each do |fl|
                if !true_flags.has_key?(fl)
                    result[fl] = false
                end
            end
            result
        end

        mock = flexmock
	task = Class.new(Roby::Task) do
            define_method(:complete_status) do
                as_array = status_flags.map { |s| [s, send(s)] }
                Hash[as_array]
            end

	    event :start do |context|
                mock.cmd_start(complete_status)
                emit :start
	    end
            on :start do |context|
                mock.on_start(complete_status)
            end
	    event :failed, :terminal => true do |context|
                mock.cmd_failed(complete_status)
                emit :failed
	    end
            on :failed do |ev|
                mock.on_failed(complete_status)
            end
	    event :stop do |context|
                mock.cmd_stop(complete_status)
                failed!
	    end
            on :stop do |context|
                mock.on_stop(complete_status)
            end
	end.new
        plan.add(task)
        task.stop_event.when_unreachable do |_|
            mock.stop_unreachable
        end

        mock.should_expect do |m|
            m.cmd_start(expected_status[:starting? => true, :success? => nil]).once.ordered
            m.on_start(expected_status[:started? => true, :running? => true, :success? => nil]).once.ordered
            m.cmd_stop(expected_status[:started? => true, :running? => true, :success? => nil]).once.ordered
            m.cmd_failed(expected_status[:started? => true, :running? => true, :finishing? => true, :success? => nil]).once.ordered
            m.on_failed(expected_status[:started? => true, :running? => true, :finishing? => true, :success? => false]).once.ordered
            m.stop_unreachable.once.ordered
            m.on_stop(expected_status[:started? => true, :finished? => true, :success? => false]).once.ordered
        end

        assert(task.pending?)
        task.start!
        task.stop!
    end

    def test_context_propagation
	FlexMock.use do |mock|
	    model = Class.new(Tasks::Simple) do
		event :start do |context|
		    mock.starting(context)
		    event(:start).emit(*context)
		end
		on(:start) do |event| 
		    mock.started(event.context)
		end


		event :pass_through, :command => true
		on(:pass_through) do |event|
		    mock.pass_through(event.context)
		end

		on(:stop)  { |event| mock.stopped(event.context) }
	    end
	    plan.add_mission(task = model.new)

	    mock.should_receive(:starting).with([42]).once
	    mock.should_receive(:started).with([42]).once
	    mock.should_receive(:pass_through).with([10]).once
	    mock.should_receive(:stopped).with([21]).once
	    task.start!(42)
	    task.pass_through!(10)
	    task.emit(:stop, 21)
	    assert(task.finished?)
	end
    end

    def test_inheritance_overloading
        base = Class.new(Roby::Task) do 
            extend Test::Unit::Assertions
            event :ctrl, :command => true
	    event :stop
            assert(!find_event_model(:stop).controlable?)
        end

        Class.new(base) do
            extend Test::Unit::Assertions

            assert_nothing_raised { event :start, :command => true }
            assert_raises(ArgumentError) { event :ctrl, :command => false }
            assert_raises(ArgumentError) { event :failed, :terminal => false }
            assert_raises(ArgumentError) { event :failed }

            assert_nothing_raised { event(:stop) { |context| } }
            assert(find_event_model(:stop).controlable?)
        end

	Class.new(base) do
	    assert_nothing_raised { event(:start) { |context| } }
	end
    end

    def test_singleton
	model = Class.new(Task) do
	    def initialize
		singleton_class.event(:start, :command => true)
		singleton_class.event(:stop)
		super
	    end
	    event :inter
	end

	ev_models = Hash[*model.enum_for(:each_event).to_a.flatten]
	assert_equal([:start, :success, :aborted, :internal_error, :updated_data, :stop, :failed, :inter].to_set, ev_models.keys.to_set)

	plan.add(task = model.new)
	ev_models = Hash[*task.model.enum_for(:each_event).to_a.flatten]
	assert_equal([:start, :success, :aborted, :internal_error, :updated_data, :stop, :failed, :inter].to_set, ev_models.keys.to_set)
	assert( ev_models[:start].symbol )
	assert( ev_models[:start].name || ev_models[:start].name.length > 0 )
    end

    def test_check_running
	model = Class.new(Tasks::Simple) do
	    event(:inter, :command => true)
	end
	plan.add(task = model.new)

        with_log_level(Roby, Logger::FATAL) do
            assert_raises(CommandFailed) { task.inter! }
            assert_raises(EmissionFailed) { task.emit(:inter) }
            assert(!task.event(:inter).pending)
            task.start!
            assert_raise(CommandFailed) { task.start! }
            assert_nothing_raised { task.inter! }
            task.stop!

            assert_raises(TaskEventNotExecutable) { task.emit(:inter) }
            assert_raises(CommandFailed) { task.inter! }
            assert(!task.event(:inter).pending)
        end

	model = Class.new(Tasks::Simple) do
	    event :start do |context|
		emit :inter
		emit :start
            end

	    event :inter do |context|
		emit :inter
            end
	end
	plan.add(task = model.new)
	assert_nothing_raised { task.start! }
    end

    def test_finished
	model = Class.new(Roby::Task) do
	    event :start, :command => true
	    event :failed, :command => true, :terminal => true
	    event :success, :command => true, :terminal => true
	    event :stop, :command => true
	end

	plan.add(task = model.new)
	task.start!
	task.emit(:stop)
	assert(!task.success?)
	assert(!task.failed?)
	assert(task.finished?)
	assert_equal(task.event(:stop).last, task.terminal_event)

	plan.add(task = model.new)
	task.start!
	task.emit(:success)
	assert(task.success?)
	assert(!task.failed?)
	assert(task.finished?)
	assert_equal(task.event(:success).last, task.terminal_event)

	plan.add(task = model.new)
	task.start!
	task.emit(:failed)
	assert(!task.success?)
	assert(task.failed?)
	assert(task.finished?)
	assert_equal(task.event(:failed).last, task.terminal_event)
    end

    def assert_exception_message(klass, msg)
        yield
        flunk 'no exception raised'
    rescue klass => e
        unless msg === e.message
            flunk "exception message '#{e.message}' does not match the expected pattern #{msg}"
        end
    rescue Exception => e
        flunk "expected an exception of class #{klass} but got #{e.full_message}"
    end

    def test_cannot_start_if_not_executable
        Roby.logger.level = Logger::FATAL
	model = Class.new(Tasks::Simple) do 
	    event(:inter, :command => true)
            def executable?; false end
	end

        plan.add(task = model.new)
        assert_raises(TaskEventNotExecutable) { task.event(:start).call }

        plan.add(task = model.new)
        assert_raises(TaskEventNotExecutable) { task.start! }
    end

    def test_cannot_leave_pending_if_not_executable
        Roby.logger.level = Logger::FATAL
        model = Class.new(Tasks::Simple) do
            def executable?; !pending?  end
        end
	plan.add(task = model.new)
        assert_raises(TaskEventNotExecutable) { task.start! }
    end

    def test_executable
	model = Class.new(Tasks::Simple) do 
	    event(:inter, :command => true)
	end
	task = model.new

	assert(!task.executable?)
	assert(!task.event(:start).executable?)
        task.executable = true
	assert(task.executable?)
	assert(task.event(:start).executable?)
        task.executable = nil
	assert(!task.executable?)
	assert(!task.event(:start).executable?)

	plan.add(task)
	assert(task.executable?)
	assert(task.event(:start).executable?)
        task.executable = false
	assert(!task.executable?)
	assert(!task.event(:start).executable?)
        task.executable = nil
	assert(task.executable?)
	assert(task.event(:start).executable?)

	# Cannot change the flag if the task is running
        task.executable = nil
        task.start!
	assert_raises(ModelViolation) { task.executable = false }
    end
	
    class ParameterizedTask < Roby::Task
        argument :arg
    end
    
    class AbstractTask < Roby::Task
        abstract
    end

    class NotExecutablePlan < Roby::Plan
        def executable?
            false
	end
    end
    
    def exception_propagator(task, relation)
	first_task  = Tasks::Simple.new
	second_task = task
	first_task.send(relation, :start, second_task, :start)
	first_task.start!
    end
    
    def assert_direct_call_validity_check(substring, check_signaling)
        with_log_level(Roby, Logger::FATAL) do
            error = yield
            assert_exception_message(TaskEventNotExecutable, substring) { error.start! }
            error = yield
            assert_exception_message(TaskEventNotExecutable, substring) {error.event(:start).call(nil)}
            error = yield
            assert_exception_message(TaskEventNotExecutable, substring) {error.event(:start).emit(nil)}
            
            if check_signaling then
                error = yield
                assert_exception_message(TaskEventNotExecutable, substring) do
                   exception_propagator(error, :signals)
                end
                error = yield
                assert_exception_message(TaskEventNotExecutable, substring) do
                   exception_propagator(error, :forward_to)
                end
            end
        end
    end

    def assert_failure_reason(task, exception, message = nil)
        if block_given?
            begin
                yield
            rescue exception
            end
        end

        assert(task.failed?, "#{task} did not fail")
        assert_kind_of(exception, task.failure_reason, "wrong error type for #{task}: expected #{exception}, got #{task.failure_reason}")
        assert(task.failure_reason.message =~ message, "error message '#{task.failure_reason.message}' was expected to match #{message}") if message
    end
    
    def assert_emission_fails(message_match, check_signaling)
        error = yield
	assert_failure_reason(error, TaskEventNotExecutable, message_match) do
            error.start!
        end
        error = yield
	assert_failure_reason(error, TaskEventNotExecutable, message_match) do
            error.event(:start).call(nil)
        end

        error = yield
        assert_exception_message(TaskEventNotExecutable, message_match) do
            error.event(:start).emit(nil)
        end
	
	if check_signaling then
	    error = yield
	    assert_exception_message(TaskEventNotExecutable, message_match) do
                exception_propagator(error, :forward_to)
            end

	    error = yield
            exception_propagator(error, :signals)
	    assert_failure_reason(error, TaskEventNotExecutable, message_match)
	end
    end
        
    def test_exception_refinement
        # test for a task that is in no plan
        assert_direct_call_validity_check(/no plan/,false) do
            Tasks::Simple.new
	end

	# test for a not executable plan
	erroneous_plan = NotExecutablePlan.new	
	assert_direct_call_validity_check(/plan is not executable/,false) do
	   erroneous_plan.add(task = Tasks::Simple.new)
	   task
	end
        erroneous_plan.clear

        # test for a not executable task
        assert_direct_call_validity_check(/is not executable/,true) do
            plan.add(task = Tasks::Simple.new)
            task.executable = false
            task
	end
        
	# test for partially instanciation
	assert_direct_call_validity_check(/partially instanciated/,true) do
	   plan.add(task = ParameterizedTask.new)
	   task
	end

        # test for an abstract task
        assert_direct_call_validity_check(/abstract/,true) do
            plan.add(task = AbstractTask.new)
            task
	end
    end
	
    

    def test_task_success_failure
	FlexMock.use do |mock|
	    plan.add_mission(t = EmptyTask.new)
	    [:start, :success, :stop].each do |name|
		t.on(name) { |event| mock.send(name) }
		mock.should_receive(name).once.ordered
	    end
	    t.start!
	end
    end

    def aggregator_test(a, *tasks)
	plan.add_mission(a)
	FlexMock.use do |mock|
	    [:start, :success, :stop].each do |name|
		a.on(name) { |ev| mock.send(name) }
		mock.should_receive(name).once.ordered
	    end
	    a.start!
	    assert( tasks.all? { |t| t.finished? })
	end
    end

    def test_task_parallel_aggregator
        t1, t2 = EmptyTask.new, EmptyTask.new
	plan.add([t1, t2])
	aggregator_test((t1 | t2), t1, t2)
        t1, t2 = EmptyTask.new, EmptyTask.new
	plan.add([t1, t2])
	aggregator_test( (t1 | t2).to_task, t1, t2 )
    end

    def task_tuple(count)
	tasks = (1..count).map do 
	    t = EmptyTask.new
	    t.executable = true
	    t
	end
	yield(tasks)
    end

    def test_sequence
	task_tuple(2) { |t1, t2| aggregator_test( (t1 + t2), t1, t2 ) }
        task_tuple(2) do |t1, t2| 
	    s = t1 + t2
	    aggregator_test( s.to_task, t1, t2 )
	    assert(! t1.event(:stop).related_object?(s.event(:stop)))
	end

	task_tuple(3) do |t1, t2, t3|
	    s = t2 + t3
	    s.unshift t1
	    aggregator_test(s, t1, t2, t3)
	end
	
	task_tuple(3) do |t1, t2, t3|
	    s = t2 + t3
	    s.unshift t1
	    aggregator_test(s.to_task, t1, t2, t3)
	end
    end
    def test_sequence_to_task
	model = Class.new(Tasks::Simple)
	t1, t2 = prepare_plan :tasks => 2, :model => Tasks::Simple

	seq = (t1 + t2)
	assert(seq.child_object?(t1, TaskStructure::Hierarchy))
	assert(seq.child_object?(t2, TaskStructure::Hierarchy))

	task = seq.to_task(model)

	plan.add_mission(task)

	assert(!seq.child_object?(t1, TaskStructure::Hierarchy))
	assert(!seq.child_object?(t2, TaskStructure::Hierarchy))

	task.start!
	assert(t1.running?)
	t1.success!
	assert(t2.running?)
	t2.success!
	assert(task.success?)
    end

    def test_compatible_state
	t1, t2 = prepare_plan :add => 2, :model => Tasks::Simple

	assert(t1.compatible_state?(t2))
	t1.start!; assert(! t1.compatible_state?(t2) && !t2.compatible_state?(t1))
	t1.stop!; assert(t1.compatible_state?(t2) && t2.compatible_state?(t1))

	plan.add(t1 = Tasks::Simple.new)
	t1.start!
	t2.start!; assert(t1.compatible_state?(t2) && t2.compatible_state?(t1))
	t1.stop!; assert(t1.compatible_state?(t2) && !t2.compatible_state?(t1))
    end

    def test_fullfills
	abstract_task_model = TaskModelTag.new do
	    argument :abstract
	end
	task_model = Class.new(Task) do
	    include abstract_task_model
	    argument :index; argument :universe
	end

	t1, t2 = task_model.new, task_model.new
	plan.add([t1, t2])
	assert(t1.fullfills?(t1.model))
	assert(t1.fullfills?(t2))
	assert(t1.fullfills?(abstract_task_model))
	
	plan.add(t2 = task_model.new(:index => 2))
	assert(!t1.fullfills?(t2))

	plan.add(t3 = task_model.new(:universe => 42))
	assert(t3.fullfills?(t1))
	assert(!t1.fullfills?(t3))
	plan.add(t3 = task_model.new(:universe => 42, :index => 21))
	assert(t3.fullfills?(task_model, :universe => 42))

	plan.add(t3 = Class.new(Task).new)
	assert(!t1.fullfills?(t3))

	plan.add(t3 = Class.new(task_model).new)
	assert(!t1.fullfills?(t3))
	assert(t3.fullfills?(t1))
    end

    def test_fullfill_using_provided_services
        tag = TaskModelTag.new
        proxy_model = Class.new(Task) do
            include tag

            @tag = tag
            class << self
                define_method(:provided_services) do
                    [@tag]
                end
            end
        end
        real_model = Class.new(Task) do
            include tag
        end

        t1, t2  = real_model.new, proxy_model.new
        assert(t1.fullfills?(t2))
        assert(t1.fullfills?([t2]))
        assert(t1.fullfills?(tag))
    end

    def test_related_tasks
	t1, t2, t3 = (1..3).map { Tasks::Simple.new }.
	    each { |t| plan.add(t) }
	t1.depends_on t2
	t1.event(:start).signals t3.event(:start)
	assert_equal([t3].to_value_set, t1.event(:start).related_tasks)
	assert_equal([t2].to_value_set, t1.related_objects)
	assert_equal([t2, t3].to_value_set, t1.related_tasks)
    end

    def test_related_events
	t1, t2, t3 = (1..3).map { Tasks::Simple.new }.
	    each { |t| plan.add(t) }
	t1.depends_on t2
	t1.event(:start).signals t3.event(:start)
	assert_equal([t3.event(:start)].to_value_set, t1.related_events)
    end

    def test_if_unreachable
	model = Class.new(Tasks::Simple) do
	    event :ready
	end

	# Test that the stop event will make the handler called on a running task
	FlexMock.use do |mock|
	    plan.add(task = model.new)
	    ev = task.event(:success)
	    ev.if_unreachable(false) { mock.success_called }
	    ev.if_unreachable(true)  { mock.success_cancel_called }
	    mock.should_receive(:success_called).once
	    mock.should_receive(:success_cancel_called).never
	    ev = task.event(:ready)
	    ev.if_unreachable(false) { mock.ready_called }
	    ev.if_unreachable(true)  { mock.ready_cancel_called }
	    mock.should_receive(:ready_called).once
	    mock.should_receive(:ready_cancel_called).once

	    task.start!
	    task.success!
	end
	engine.garbage_collect

	# Test that it works on pending tasks too
	FlexMock.use do |mock|
	    plan.add(task = model.new)
	    ev = task.event(:success)
	    ev.if_unreachable(false) { mock.success_called }
	    ev.if_unreachable(true)  { mock.success_cancel_called }
	    mock.should_receive(:success_called).once
	    mock.should_receive(:success_cancel_called).once

	    ev = task.event(:ready)
	    ev.if_unreachable(false) { mock.ready_called }
	    ev.if_unreachable(true)  { mock.ready_cancel_called }
	    mock.should_receive(:ready_called).once
	    mock.should_receive(:ready_cancel_called).once

	    engine.garbage_collect
	end

    end

    def test_stop_becomes_unreachable
	FlexMock.use do |mock|
	    plan.add(task = Roby::Tasks::Simple.new)
            ev = task.stop_event
	    ev.if_unreachable(false) { mock.stop_called }
	    ev.if_unreachable(true)  { mock.stop_cancel_called }

            mock.should_receive(:stop_called).once
            mock.should_receive(:stop_cancel_called).never
            task.start!
            task.stop!
        end
    end

    def test_achieve_with
	slave  = Tasks::Simple.new
	master = Class.new(Task) do
	    terminates
	    event :start do |context|
		event(:start).achieve_with slave
	    end
	end.new
	plan.add([master, slave])

	master.start!
	assert(master.starting?)
	assert(master.depends_on?(slave))
	slave.start!
	slave.success!
	assert(master.started?)

	slave  = Tasks::Simple.new
	master = Class.new(Task) do
	    event :start do |context|
		event(:start).achieve_with slave.event(:start)
	    end
	end.new
	plan.add([master, slave])

	master.start!
	assert(master.starting?)
	plan.remove_object(slave)
        assert master.failed?
        assert_kind_of UnreachableEvent, master.failure_reason
    end

    def test_task_group
	t1, t2 = Tasks::Simple.new, Tasks::Simple.new
	plan.add(g = Group.new(t1, t2))

	g.start!
	assert(t1.running?)
	assert(t2.running?)

	t1.success!
	assert(g.running?)
	t2.success!
	assert(g.success?)
    end

    def test_poll
	engine.run

	FlexMock.use do |mock|
	    t = Class.new(Tasks::Simple) do
		poll do
		    mock.polled_from_model(running?, self)
		end
	    end.new
            t.poll do
                mock.polled_from_instance(t.running?, t)
            end
	    mock.should_receive(:polled_from_model).at_least.once.with(true, t)
	    mock.should_receive(:polled_from_instance).at_least.once.with(true, t)

	    engine.execute do
		plan.add_permanent(t)
		t.start!
	    end
	    engine.wait_one_cycle

            # Verify that the poll block gets deregistered when  the task is
            # finished
	    engine.execute do
		assert(t.running?, t.terminal_event.to_s)
                plan.unmark_permanent(t) # avoid error handling
		t.stop!
	    end
	    engine.wait_one_cycle
            assert(!t.running?)
	    engine.wait_one_cycle
	end
    end

    def test_error_in_polling
        Roby.logger.level = Logger::FATAL
        Roby::ExecutionEngine.logger.level = Logger::FATAL
	FlexMock.use do |mock|
	    mock.should_receive(:polled).once
	    klass = Class.new(Tasks::Simple) do
		poll do
		    mock.polled(self)
		    raise ArgumentError
		end
	    end

            engine.run

            t = nil
            engine.execute do
                plan.add_permanent(t = klass.new)
            end
            assert_event_emission(t.internal_error_event) do
                t.start!
            end
            assert(t.stop?)
	end
    end

    def test_error_in_polling_with_delayed_stop
        Roby.logger.level = Logger::FATAL
        t = nil
	FlexMock.use do |mock|
	    mock.should_receive(:polled).once
	    klass = Class.new(Tasks::Simple) do
		poll do
		    mock.polled(self)
		    raise ArgumentError
		end

                event :stop do |ev|
                end
	    end

            engine.run

            engine.execute do
                plan.add_permanent(t = klass.new)
            end
            assert_event_emission(t.internal_error_event) do
                t.start!
            end
            assert(t.failed?)
            assert(t.running?)
            assert(t.finishing?)
            engine.execute do
                t.emit :stop
            end
            assert(t.failed?)
            assert(!t.running?)
            assert(t.finished?)
	end

    ensure
        if t.running?
            engine.execute { t.emit :stop }
        end
    end

    def test_events_emitted_multiple_times
        # We generate an error, avoid having a spurious "non-fatal error"
        # message
        Roby::ExecutionEngine.make_own_logger(nil, Logger::FATAL)

	FlexMock.use do |mock|
	    mock.should_receive(:polled).once
	    mock.should_receive(:emitted).once
	    klass = Class.new(Tasks::Simple) do
		poll do
		    mock.polled(self)
                    emit :internal_error
                    emit :internal_error
		end
                on :internal_error do |ev|
                    mock.emitted
                end
	    end

            engine.run

            t = nil
            engine.execute do
                plan.add_permanent(t = klass.new)
            end
            assert_event_emission(t.stop_event) do
                t.start!
            end
	end
    end

    def test_event_task_sources
	task = Class.new(Tasks::Simple) do
	    event :specialized_failure, :command => true
	    forward :specialized_failure => :failed
	end.new
	plan.add(task)

	task.start!
	assert_equal([], task.event(:start).last.task_sources.to_a)

	ev = EventGenerator.new(true)
	ev.forward_to task.event(:specialized_failure)
	ev.call
	assert_equal([task.event(:failed).last], task.event(:stop).last.task_sources.to_a)
	assert_equal([task.event(:specialized_failure).last, task.event(:failed).last].to_value_set, task.event(:stop).last.all_task_sources.to_value_set)
    end

    def test_virtual_task
	start, success = EventGenerator.new(true), EventGenerator.new
	assert_raises(ArgumentError) { VirtualTask.create(success, start) }

	assert_kind_of(VirtualTask, task = VirtualTask.create(start, success))
	plan.add(task)
	assert_equal(start, task.start_event)
	assert_equal(success, task.success_event)
	FlexMock.use do |mock|
	    start.on { |event| mock.start_event }
	    task.event(:start).on { |event| mock.start_task }
	    mock.should_receive(:start_event).once.ordered
	    mock.should_receive(:start_task).once.ordered
	    task.start!

	    success.emit
	    assert(task.success?)
	end

	start, success = EventGenerator.new(true), EventGenerator.new
	plan.add(task = VirtualTask.create(start, success))
	task.start!
	plan.remove_object(success)
	assert(task.failed?)

	start, success = EventGenerator.new(true), EventGenerator.new
	plan.add(success)
	plan.add(task = VirtualTask.create(start, success))
	assert_nothing_raised { success.emit }
    end

    def test_dup
        model = Class.new(Roby::Test::Tasks::Simple) do
            event :intermediate
        end
	plan.add(task = model.new)
	task.start!
        task.emit :intermediate

	new = task.dup
	assert_not_same(new.event(:stop), task.event(:stop))
	assert_same(new, new.event(:stop).task)

	assert(!plan.include?(new))
        assert_equal(nil, new.plan)

	assert_kind_of(Roby::TaskArguments, new.arguments)
	assert_equal(task.arguments.to_hash, new.arguments.to_hash)

        plan.add(new)
	assert_equal([new.event(:stop)], new.event(:failed).child_objects(Roby::EventStructure::Forwarding).to_a)

        assert(task.running?)
        assert(new.running?)
        assert(task.intermediate?)
        assert(new.intermediate?)

	task.stop!
	assert(!task.running?)
	assert(new.running?)

	new.event(:stop).call
	assert(new.stop?, "#{new} should have emitted stop but did not, history: #{new.history.map(&:to_s).join(", ")}")
	assert(new.finished?, "#{new} should have finished but did not, history: #{new.history.map(&:to_s).join(", ")}")
    end

    def test_failed_to_start
	plan.add(task = Roby::Test::Tasks::Simple.new)
        begin
            task.event(:start).emit_failed
        rescue Exception
        end
        assert task.failed_to_start?
        assert_kind_of EmissionFailed, task.failure_reason
        assert task.failed?
        assert !task.pending?
        assert !task.running?
        assert_equal [], plan.find_tasks.pending.to_a
        assert_equal [], plan.find_tasks.running.to_a
        assert_equal [task], plan.find_tasks.failed.to_a
    end

    def test_cannot_call_event_on_task_that_failed_to_start
	plan.add(task = Roby::Test::Tasks::Simple.new)
        begin
            task.event(:start).emit_failed
        rescue Exception
        end
        assert task.failed_to_start?
        assert_raises(Roby::CommandFailed) { task.stop! }
    end

    def test_cannot_call_event_on_task_that_finished
	plan.add(task = Roby::Test::Tasks::Simple.new)
        task.start_event.emit
        task.stop_event.emit
        assert_raises(Roby::CommandFailed) { task.stop! }
    end

    def test_intermediate_emit_failed
        model = Class.new(Tasks::Simple) do
            event :intermediate
        end
	plan.add(task = model.new)
        task.start!

        task.event(:intermediate).emit_failed
        assert(task.internal_error?)
        assert(task.failed?)
        assert_kind_of EmissionFailed, task.failure_reason
        assert_equal(task.event(:intermediate), task.failure_reason.failed_generator)
    end

    def test_emergency_termination_fails
        model = Class.new(Tasks::Simple) do
            event :command_fails do |context|
                raise ArgumentError
            end
            event :emission_fails
        end
	plan.add(task = model.new)
        task.start!

        task.command_fails!
        assert(task.internal_error?)
        assert(task.failed?)
        assert_kind_of CommandFailed, task.failure_reason
        assert_equal(task.event(:command_fails), task.failure_reason.failed_generator)

        plan.add(task = model.new)
        task.start!
        task.emission_fails_event.emit_failed
        assert(task.internal_error?)
        assert(task.failed?)
        assert_kind_of EmissionFailed, task.failure_reason
    end

    def test_emergency_termination_in_terminal_commands
        mock = flexmock
        mock.should_expect do |m|
            m.cmd_stop.once.ordered
            m.cmd_failed.once.ordered
        end

        model = Class.new(Tasks::Simple) do
            event :failed, :terminal => true do |context|
                mock.cmd_failed
                raise ArgumentError
            end
            event :stop, :terminal => true do |context|
                mock.cmd_stop
                failed!
            end
        end
	plan.add(task = model.new)
        task.start!

        with_log_level(Roby, Logger::FATAL) do
            assert_raises(Roby::TaskEmergencyTermination) do
                task.stop!
            end
        end

    ensure
        if task
            task.forcefully_terminate
            plan.remove_object(task)
        end
    end

    def test_nil_default_argument
        model = Class.new(Tasks::Simple) do
            argument 'value', :default => nil
        end
        task = model.new
        assert task.fully_instanciated?
        assert !task.arguments.static?
	plan.add(task)
	assert task.executable?
	task.start!
	assert_equal nil, task.arguments[:value]
    end

    def test_plain_default_argument
        model = Class.new(Tasks::Simple) do
            argument 'value', :default => 10
        end
        task = model.new
        assert task.fully_instanciated?
        assert !task.arguments.static?
	plan.add(task)
	assert task.executable?
	task.start!
	assert_equal 10, task.arguments['value']
    end

    def test_delayed_default_argument
        has_value = false
        value = nil
        block = lambda do |task|
            if has_value
                value
            else
                throw :no_value
            end
        end

        model = Class.new(Roby::Task) do
            terminates
            argument 'value', :default => (Roby::DelayedTaskArgument.new(&block))
        end
        task = model.new
        assert !task.arguments.static?

        assert_equal nil, task.value
        assert !task.fully_instanciated?
        has_value = true
        assert_equal nil, task.value
        assert task.fully_instanciated?

        value = 10
        assert task.fully_instanciated?
        has_value = false
        assert_equal nil, task.value
        assert !task.fully_instanciated?

        has_value = true
        plan.add(task)
        task.start!
        assert_equal 10, task.arguments[:value]
        assert_equal 10, task.value
    end

    def test_delayed_argument_from_task
        value_obj = Class.new do
            attr_accessor :value
        end.new

        klass = Class.new(Roby::Task) do
            terminates
            argument :arg, :default => from(:planned_task).arg.of_type(Numeric)
        end

        planning_task = klass.new
        planned_task  = klass.new
        planned_task.planned_by planning_task
        plan.add(planned_task)

        assert !planning_task.arguments.static?
        assert !planning_task.fully_instanciated?
        planned_task.arg = Object.new
        assert !planning_task.fully_instanciated?
        plan.force_replace_task(planned_task, (planned_task = klass.new))
        planned_task.arg = 10
        assert planning_task.fully_instanciated?
        planning_task.start!
        assert_equal 10, planning_task.arg
    end

    def test_delayed_argument_from_object
        value_obj = Class.new do
            attr_accessor :value
        end.new

        klass = Class.new(Roby::Task) do
            terminates
            argument :arg
        end
        task = klass.new(:arg => Roby.from(value_obj).value.of_type(Integer))
        plan.add(task)

        assert !task.arguments.static?
        assert !task.fully_instanciated?
        value_obj.value = 10
        assert task.fully_instanciated?
        assert_equal nil, task.arg
        value_obj.value = 20
        task.start!
        assert_equal 20, task.arg
    end

    def test_as_plan
        plan.add(task = Tasks::Simple.new)
        model = Class.new(Tasks::Simple)

        child = task.depends_on(model)
        assert_kind_of model, child
        assert task.depends_on?(child)
    end

    def test_as_plan_with_arguments
        plan.add(task = Tasks::Simple.new)
        model = Class.new(Tasks::Simple)

        child = task.depends_on(model.with_arguments(:id => 20))
        assert_kind_of model, child
        assert_equal 20, child.arguments[:id]
        assert task.depends_on?(child)
    end

    def test_can_merge_model
        test_model1 = Class.new(Roby::Task)
        test_model2 = Class.new(Roby::Task)
        test_model3 = Class.new(test_model1)

        t1 = test_model1.new
        t2 = test_model2.new
        t3 = test_model3.new

        assert(t1.can_merge?(t1))
        assert(t3.can_merge?(t1))
        assert(!t1.can_merge?(t3))
        assert(!t1.can_merge?(t2))

        assert(!t3.can_merge?(t2))
        assert(!t2.can_merge?(t3))
    end

    def test_can_merge_arguments
        test_model = Class.new(Roby::Task) do
            argument :id
        end
        t1 = test_model.new
        t2 = test_model.new

        assert(t1.can_merge?(t2))
        assert(t2.can_merge?(t1))

        t2.arguments[:id] = 10
        assert(t1.can_merge?(t2))
        assert(t2.can_merge?(t1))

        t1.arguments[:id] = 20
        assert(!t1.can_merge?(t2))
        assert(!t2.can_merge?(t1))
    end

    def test_poll_handlers_with_replacing
        model = Class.new(Roby::Task) do
            terminates
        end
        old, new = prepare_plan :missions => 2, :model => model

        FlexMock.use do |mock|
            old.poll { |task| mock.should_not_be_passed_on(task) }
            old.poll(:on_replace => :copy) { |task| mock.should_be_passed_on(task) }

            plan.replace(old, new)

            assert_equal(1, new.poll_handlers.size)
            assert_equal(new.poll_handlers[0].block, old.poll_handlers[1].block)

            old.start!
            new.start!
            mock.should_receive(:should_not_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(new).once

            process_events
        end
    end

    def test_event_handlers_with_replacing
        model = Class.new(Roby::Task) do
            terminates
        end
        old, new = prepare_plan :missions => 2, :model => model

        FlexMock.use do |mock|
            old.start_event.on { |event| mock.should_not_be_passed_on(event.task) }
            old.start_event.on(:on_replace => :copy) { |event| mock.should_be_passed_on(event.task) }

            plan.replace(old, new)

            assert_equal(1, new.start_event.handlers.size)
            assert_equal(new.start_event.handlers[0].block, old.start_event.handlers[1].block)

            mock.should_receive(:should_be_passed_on).with(new).once
            mock.should_receive(:should_be_passed_on).with(old).once
            mock.should_receive(:should_not_be_passed_on).with(old).once
            old.start!
            new.start!
        end
    end

    def test_abstract_tasks_automatically_mark_the_poll_handlers_as_replaced
        abstract_model = Class.new(Roby::Task) do
            abstract

            def fullfilled_model
                [Roby::Task]
            end
        end
        plan.add_permanent(old = abstract_model.new)
        plan.add_permanent(new = Roby::Tasks::Simple.new)

        FlexMock.use do |mock|
            old.poll { |task| mock.should_be_passed_on(task) }
            old.poll(:on_replace => :drop) { |task| mock.should_not_be_passed_on(task) }

            plan.replace(old, new)
            new.start!

            assert_equal(1, new.poll_handlers.size, new.poll_handlers.map(&:block))
            assert_equal(new.poll_handlers[0].block, old.poll_handlers[0].block)

            mock.should_receive(:should_be_passed_on).with(new).once
            process_events
        end
    end

    def test_abstract_tasks_automatically_mark_the_event_handlers_as_replaced
        abstract_model = Class.new(Roby::Task) do
            abstract

            def fullfilled_model
                [Roby::Task]
            end
        end
        plan.add_mission(old = abstract_model.new)
        plan.add_mission(new = Roby::Tasks::Simple.new)

        FlexMock.use do |mock|
            old.start_event.on { |event| mock.should_be_passed_on(event.task) }
            old.start_event.on(:on_replace => :drop) { |event| mock.should_not_be_passed_on(event.task) }

            plan.replace(old, new)
            assert_equal(1, new.start_event.handlers.size)
            assert_equal(new.start_event.handlers[0].block, old.start_event.handlers[0].block)

            mock.should_receive(:should_not_be_passed_on).never
            mock.should_receive(:should_be_passed_on).with(new).once
            new.start!
        end
    end

    def test_finalization_handlers_with_replacing
        model = Class.new(Roby::Task) do
            terminates
        end
        old, new = prepare_plan :missions => 2, :model => model

        FlexMock.use do |mock|
            mock.should_receive(:should_not_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(new).once

            old.when_finalized { |task| mock.should_not_be_passed_on(task) }
            old.when_finalized(:on_replace => :copy) { |task| mock.should_be_passed_on(task) }

            plan.replace(old, new)
            assert_equal(1, new.finalization_handlers.size)
            assert_equal(new.finalization_handlers[0].block, old.finalization_handlers[1].block)

            plan.remove_object(old)
            plan.remove_object(new)
        end
    end

    def test_finalization_handlers_are_copied_by_default_on_abstract_tasks
        model = Class.new(Roby::Task) do
            terminates
        end
        old = prepare_plan :add => 1, :model => Roby::Task
        new = prepare_plan :add => 1, :model => model

        FlexMock.use do |mock|
            mock.should_receive(:should_not_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(new).once

            old.when_finalized(:on_replace => :drop) { |task| mock.should_not_be_passed_on(task) }
            old.when_finalized { |task| mock.should_be_passed_on(task) }

            plan.replace(old, new)
            assert_equal(1, new.finalization_handlers.size)
            assert_equal(new.finalization_handlers[0].block, old.finalization_handlers[1].block)

            plan.remove_object(old)
            plan.remove_object(new)
        end
    end

    def test_plain_all_and_root_sources
        source, target = prepare_plan :add => 2, :model => Roby::Tasks::Simple
        source.stop_event.forward_to target.aborted_event

        source.start!
        target.start!
        source.stop!
        event = target.stop_event.last

        assert_equal [target.failed_event].map(&:last).to_value_set, event.sources.to_value_set
        assert_equal [source.failed_event, source.stop_event, target.aborted_event, target.failed_event].map(&:last).to_value_set, event.all_sources.to_value_set
        assert_equal [source.failed_event].map(&:last).to_value_set, event.root_sources.to_value_set

        assert_equal [target.failed_event].map(&:last).to_value_set, event.task_sources.to_value_set
        assert_equal [target.aborted_event, target.failed_event].map(&:last).to_value_set, event.all_task_sources.to_value_set
        assert_equal [target.aborted_event].map(&:last).to_value_set, event.root_task_sources.to_value_set
    end

    def test_task_as_plan
        task_t = Class.new(Roby::Task)
        task, planner_task = task_t.new, task_t.new

        planner = flexmock
        planning_method = flexmock(:name => 'm1', :returns => task_t)
        flexmock(Robot).should_receive(:action_from_model).with(task_t).and_return([planner, planning_method])

        as_plan = task_t.as_plan
        plan.add(as_plan)
        assert_kind_of(task_t, as_plan)

        planner_task = as_plan.planning_task
        assert_kind_of(Roby::PlanningTask, planner_task)
        assert_equal(planning_method, planner_task.planning_method)
        assert_equal(task_t, planner_task.planned_model)
        assert_equal(planner, planner_task.planner_model)
        assert_equal("m1", planner_task.method_name)
    end
end

