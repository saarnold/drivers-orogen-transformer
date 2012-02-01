require 'transformer'

module Transformer
    # Exception raised when a frame is being selected with #selected_frame, but
    # the selection is invalid
    #
    # The reason for the invalidity is (for now) stored only in the message
    class InvalidFrameSelection < RuntimeError
        # The task for which the selection was done
        attr_reader :task
        # The task's frame name
        attr_reader :frame
        # List of [task, port] pairs that give information about why we are
        # updating the frame
        attr_reader :related_ports

        def initialize(task, frame)
            @task, @frame = task, frame
            @related_ports = Array.new
        end

        def pretty_print_related_ports(pp)
            pp.seplist(related_ports) do |src|
                task, port_name, info = *src
                pp.text "#{src[0]}.#{src[1]}: #{info}"
            end
        end
    end

    # Exception raised when two different frames are being selected for the same
    # task/frame_name pair
    class FrameSelectionConflict < InvalidFrameSelection
        # The currently selected frame
        attr_reader :current_frame
        # The newly selected frame
        attr_reader :new_frame

        def initialize(task, frame, current, new)
            super(task, frame)
            @current_frame = current
            @new_frame = new
        end

        def pretty_print(pp)
            pp.text "conflicting frames selected for #{task}.#{frame}: #{current_frame} != #{new_frame}"
            if !related_ports.empty?
                pp.breakable
                pp.text "related ports:"
                pp.nest(2) do
                    pp.breakable
                    pretty_print_related_ports(pp)
                end
            end
        end
    end

    # Exception thrown in #merge if the merged task has a different frame
    # selection than the merging task
    class FrameSelectionConflictDuringMerge < FrameSelectionConflict
        # The task that was being merged
        attr_reader :merged_task

        def initialize(merging_task, merged_task, frame, current, new)
            super(merging_task, frame, current, new)
            @merged_task = merged_task
        end

        def pretty_print(pp)
            pp.text "while doing #{task}.merge(#{merged_task})"
            pp.breakable
            super
        end
    end

    # Exception raised when #select_frame is called on a static frame with a
    # different name than the frame's static name
    class StaticFrameChangeError < InvalidFrameSelection
        # The name of the frame that was being assigned to a static frame
        attr_reader :new_frame
        def initialize(task, frame, current, new)
            super(task, frame)
            @new_frame = new
        end
        def pretty_print(pp)
            pp.text "cannot change frame #{task}.#{frame} to #{new_frame}, as the component does not support it"
            if !related_ports.empty?
                pp.text "related ports:"
                pp.nest(2) do
                    pp.breakable
                    pretty_print_related_ports(pp)
                end
            end
        end
    end

    # Exception raised during network generation if the system cannot find a
    # production chain for a transformation
    class InvalidChain < RuntimeError
        # The task for which the transformation was being produced
        attr_reader :task
        # The task-local name for the source frame
        attr_reader :task_from
        # The task-local name for the target frame
        attr_reader :task_to
        # The global name for the source frame
        attr_reader :from
        # The global name for the target frame
        attr_reader :to
        # The exception explaining the error
        attr_reader :reason

        def initialize(task, task_from, from, task_to, to, reason)
            @task, @task_from, @from, @task_to, @to, @reason =
                task, task_from, from, task_to, to, reason
        end

        def pretty_print(pp)
            pp.text "cannot find a production chain for #{from} => #{to}"
            pp.breakable
            pp.text "  in #{task}"
            pp.breakable
            pp.text "  (task-local: #{task_from} => #{task_to})"
            pp.breakable
            reason.pretty_print(pp)
        end
    end

    # Exception raised during network generation if a declared producer cannot
    # provide the required transformation
    class TransformationPortNotFound < RuntimeError
        attr_reader :task
        attr_reader :from
        attr_reader :to

        def initialize(task, from, to)
            @task, @from, @to = task, from, to
        end

        def pretty_print(pp)
            pp.text "cannot find a port providing the transformation #{from} => #{to} on"
            pp.breakable
            task.pretty_print(pp)
        end
    end
    # Exception raised during network generation if multiple ports can provide
    # a required transformation
    class TransformationPortAmbiguity < RuntimeError
        attr_reader :task
        attr_reader :from
        attr_reader :to
        attr_reader :candidates

        def initialize(task, from, to, candidates)
            @task, @from, @to, @candidates = task, from, to, candidates
        end

        def pretty_print(pp)
            pp.text "multiple candidate ports to provide the transformation #{from} => #{to} on"
            pp.nest(2) do
                pp.breakable
                task.pretty_print(pp)
            end
            pp.text "Candidates:"
            pp.nest(2) do
                pp.breakable
                pp.seplist(candidates) do |c|
                    c.pretty_print(pp)
                end
            end
        end
    end

    # Module used to extend the device specification objects with the ability
    # to specify frames
    #
    # The #frame attribute allows to specify in which frame this device
    # produces information.
    module DeviceExtension
        ## 
        # Declares the frame in which this device produces data
        dsl_attribute :frame do |value|
            value.to_str
        end

        ## 
        # Declares the frame transformation in which this device produces
        # transformations
        dsl_attribute :frame_transform do |value|
            if value.kind_of?(Transform)
                value
            else
                if !value.kind_of?(Hash)
                    raise ArgumentError, "expected a from => to mapping, got #{value}"
                elsif value.size > 1
                    raise ArgumentError, "more than one transformation provided"
                end
                Transform.new(*value.to_a.first)
            end
        end
    end

    # Module used to extend the instance specification objects with the ability
    # to map frame names to global frame names
    #
    # A frame mapping applies recursively on all levels of the hierarchy. I.e.
    # it applies on the particular instance and on all its children.
    module InstanceRequirementsExtension
        # The set of frame mappings defined on this specification
        attribute(:frame_mappings) { Hash.new }
        # The set of transformation producers defined on this specification
        attribute(:transform_producers) { Hash.new }

        # Declare frame mappings
        #
        # For instance, doing
        #
        #   use_frames("world" => "odometry")
        #
        # will assign the "odometry" global frame to every task frame called "world".
        def use_frames(frame_mappings)
            self.frame_mappings.merge!(frame_mappings)
            self
        end

        # Declare a specialized transformation producer for this requirements
        # and its children
        def use_transform_producer(from, to, producer)
            self.transform_producers[[from, to]] = producer
            self
        end

        # Updates the frame mappings when merging two instance requirements
        def merge(other_spec)
            super if defined? super

            frame_mappings.merge!(other_spec.frame_mappings) do |frame_name, sel0, sel1|
                if !sel0 then sel1
                elsif !sel1 then sel0
                elsif sel0 != sel1
                    raise ArgumentError, "cannot merge #{self} and #{other_spec}: frame mapping for #{frame_name} differ (resp. #{sel0.inspect} and #{sel1.inspect})"
                else
                    sel0
                end
            end

            transform_producers.merge!(other_spec.transform_producers) do |(from, to), sel0, sel1|
                if sel0 != sel1
                    raise ArgumentError, "cannot merge #{self} and #{other_spec}: producer for #{from} => #{to} differ (resp. #{sel0} and #{sel1})"
                end
                sel0
            end
        end

        # Displays the frame mappings when pretty-print an InstanceRequirements
        # object
        #
        # Unlike "normal" pretty-printing, one must always start with a
        # pp.breakable
        def pretty_print(pp)
            super if defined? super

            pp.breakable
            pp.text "Frame Selection:"
            if !frame_mappings.empty?
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(frame_mappings) do |mapping|
                        pp.text "#{mapping.first} => #{mapping.last}"
                    end
                end
            end
        end
    end

    # Module used to extend objects of the class Orocos::RobyPlugin::TaskContext
    module ComponentExtension
        attribute(:selected_frames) { Hash.new }
        # The set of specialized transformation producers defined for this task
        attribute(:transform_producers) { Hash.new }

        def can_merge?(other)
            if !(result = super)
                return result
            end

            selected_frames.each do |task_frame, selected_frame|
                if other_sel = other.selected_frames[task_frame]
                    if other_sel != selected_frame
                        return false
                    end
                end
            end

            transform_producers.each do |from_to, spec|
                if other_spec = other.transform_producers[from_to]
                    if other_spec != spec
                        return false
                    end
                end
            end

            return true
        end

        # Selects +selected_frame+ for the task's +frame_name+
        #
        # @throws FrameSelectionConflict if a different frame was already selected
        def select_frame(frame_name, selected_frame)
            if current = selected_frames[frame_name]
                if current != selected_frame
                    raise FrameSelectionConflict.new(self, frame_name, current, selected_frame), "cannot select both #{current} and #{selected_frame} for the frame #{frame_name} of #{self}"
                end
            else
                selected_frames[frame_name] = selected_frame
            end
        end

        # Selects a set of frame mappings
        #
        # See #select_frame
        def select_frames(mappings)
            mappings.each do |name, selected_frame|
                select_frame(name, selected_frame)
            end
        end

        # Returns true if the specified transformation is provided through a
        # dedicated port on the task, or if it should be built by the
        # transformer by aggregating information from dynamic_transformations
        #
        # The frame names are actual frame names, not task-local ones
        def find_transformation_input(from, to)
            return if !(tr = model.transformer)
            tr.each_transform_port do |port, transform|
                if port.kind_of?(Orocos::Spec::InputPort)
                    port_from = selected_frames[transform.from]
                    port_to   = selected_frames[transform.to]
                    if port_from == from && port_to == to
                        return port
                    end
                end
            end
            nil
        end

        # Returns true if one of the task's input port is configured to provide
        # the requested transformation
        def has_transformation_input?(from, to)
            !!find_transformation_input(from, to)
        end
    end

    # Extensions to the Component class
    module ComponentModelExtension
        # This returns an InstanciatedComponent object that can be used in
        # other #use statements in the deployment spec
        #
        # For instance,
        #
        #   add(Cmp::CorridorServoing).
        #       use(Project::Task.use_frame('body' => 'local_frame'))
        #
        def use_frames(*spec, &block)
            Orocos::RobyPlugin::Engine.create_instanciated_component(nil, nil, self).use_frames(*spec, &block)
        end

        # This returns an InstanciatedComponent object that can be used in
        # other #use statements in the deployment spec
        #
        # For instance,
        #
        #   add(Cmp::CorridorServoing).
        #       use(Project::Task.use_transform_producer('body', 'local_frame', Cmp::Actuator.use(Hokuyo::Task)))
        #
        def use_transform_producer(*spec, &block)
            Orocos::RobyPlugin::Engine.create_instanciated_component(nil, nil, self).use_transform_producer(*spec, &block)
        end
    end

    module CompositionExtension
        # Returns an output port object that is providing the requested
        # transformation, or nil if none can be found
        #
        # Raises TransformationPortAmbiguity if multiple ports match.
        def find_port_for_transform(from, to)
            associated_candidates = []
            type_candidates = []
            model.each_output_port do |port|
                next if !Transformer.transform_port?(port)

                if transform = find_transform_of_port(port.name)
                    if transform.from == from && transform.to == to
                        return port
                    elsif ((transform.from == from || !transform.from) && (transform.to == to || !transform.to))
                        associated_candidates << port
                    end
                else
                    type_candidates << port
                end
            end

            if associated_candidates.size == 1
                return associated_candidates.first
            elsif associated_candidates.size > 1
                raise TransformationPortAmbiguity.new(self, from, to, associated_candidates)
            end

            if type_candidates.size == 1
                return type_candidates.first
            elsif type_candidates.size > 1
                raise TransformationPortAmbiguity.new(self, from, to, candidates)
            end

            return nil
        end

        def select_port_for_transform(port, from, to)
            port = if port.respond_to?(:to_str) then port
                   else port.name
                   end

            self.each_concrete_input_connection(port) do |source_task, source_port, sink_port, policy|
                source_task.select_port_for_transform(source_port, from, to)
                return
            end
        end

        def find_transform_of_port(port)
            port = if port.respond_to?(:to_str) then port
                   else port.name
                   end

            self.each_concrete_input_connection(port) do |source_task, source_port, sink_port, policy|
                return source_task.find_transform_of_port(source_port)
            end
        end
    end

    # Module that extends the TaskContext class itself
    module TaskContextExtension
        # The set of static transformations that should be provided to the
        # component at configuration time
        attribute(:static_transforms) { Array.new }

        # Returns the transformation that this port provides, using the actual
        # frames (i.e. not the task-level frames, but the frames actually
        # selected).
        #
        # One or both frames might be nil. The return value is nil if no
        # transform is associated at all with this port
        def find_transform_of_port(port)
            return if !(tr = model.transformer)
            if associated_transform = tr.find_transform_of_port(port)
                from = selected_frames[associated_transform.from]
                to   = selected_frames[associated_transform.to]
                Transform.new(from, to)
            end
        end

        # Yields the task output ports that produce a transformation, along with
        # the selected frames for this port
        #
        # The selected frames might be nil if no transformation has been
        # selected
        def each_transform_output
            if !(tr = model.transformer)
                return
            end

            model.each_output_port do |port|
                if associated_transform = tr.find_transform_of_port(port)
                    from = selected_frames[associated_transform.from]
                    to   = selected_frames[associated_transform.to]
                    yield(port, from, to)
                end
            end
        end

        # Returns an output port object that is providing the requested
        # transformation, or nil if none can be found
        #
        # Raises TransformationPortAmbiguity if multiple ports match.
        def find_port_for_transform(from, to)
            return if !(tr = model.transformer)

            not_candidates = []
            candidates = []
            each_transform_output do |port, port_from, port_to|
                if port_from == from && port_to == to
                    return port
                elsif ((!port_from || port_from == from) && (!port_to || port_to == to))
                    candidates << port
                else
                    not_candidates << port
                end
            end

            if candidates.size == 1
                return candidates.first
            elsif candidates.size > 1
                raise TransformationPortAmbiguity.new(self, from, to, candidates)
            end

            model.each_output_port do |port|
                next if not_candidates.include?(port)
                if Transformer.transform_port?(port)
                    candidates << port
                end
            end

            if candidates.size == 1
                return candidates.first
            elsif candidates.size > 1
                raise TransformationPortAmbiguity.new(self, from, to, candidates)
            end

            return nil
        end

        # Given a port associated with a transformer transformation, assign the
        # given frames to this local transformation
        def select_port_for_transform(port, from, to)
            if !(tr = model.transformer)
                tr = model.transformer do
                    transform_output port.name, from => to
                end
            end

            if !(transform = tr.find_transform_of_port(port))
                transform = tr.transform_output(port.name, from => to)
            end
            select_frames(transform.from => from, transform.to => to)
        end

        # Adds a test to the can_merge? predicate to avoid merging two tasks
        # that have different frame mappings
        def can_merge?(merged_task)
            if !(merge_result = super)
                return merge_result
            end

            if tr = self.model.transformer
                tr.available_frames.each do |frame_name|
                    this_sel = merged_task.selected_frames[frame_name]
                    if this_sel && (sel = selected_frames[frame_name])
                        if this_sel != sel
                            Orocos::RobyPlugin::NetworkMergeSolver.debug { "cannot merge #{merged_task} into #{self}: frame selection for #{frame_name} differs (resp. #{merged_task.selected_frames[frame_name]} and #{sel})" }
                            return false
                        end
                    end
                end
            end
            return true
        end

        # Adds a pass in the merge operation that updates the selected frames
        # mapping with the mappings stored in the merged task
        def merge(merged_task)
            new = merged_task.static_transforms.find_all do |trsf|
                !static_transforms.any? { |t| t.from == trsf.from && t.to == trsf.to }
            end
            static_transforms.concat(new)

            selected_frames.merge!(merged_task.selected_frames) do |k, v1, v2|
                if v1 && v2 && v1 != v2
                    raise FrameSelectionConflictDuringMerge.new(self, merged_task, k, v1, v2),
                        "cannot merge #{merged_task} into #{self} as different frames are selected for #{k}: resp. #{v1} and #{v2}"
                end
                v1 || v2
            end
            super if defined? super
        end

        # Select the given global frame names for task-local frames.
        #
        # Example:
        #
        #    select_frames 'local' => 'global'
        #
        # Raises StaticFrameChangeError if 'local' is a static frame (i.e. no
        # property exists to change it) and 'global' is not its hardcoded value.
        def select_frames(selection)
            if tr = self.model.transformer
                selection.each do |local_frame, global_frame|
                    # If the frame is not configurable, raise
                    if tr.static?(local_frame) && local_frame != global_frame
                        raise StaticFrameChangeError.new(self, local_frame), "cannot select a frame name different than #{local_frame} for #{self}, as the component does not support configuring that frame"
                    end
                end
            end
            super
        end

        # Applies the selected frames to the task properties
        def configure
            super if defined? super
            if tr = self.model.transformer
                selected_frames.each do |local_frame, global_frame|
                    if orogen_task.has_property?("#{local_frame}_frame")
                        property("#{local_frame}_frame").write(global_frame)
                    end
                end

                if !static_transforms.empty?
                    orogen_task.static_transformations = static_transforms.map do |trsf|
                        rbs = Types::Base::Samples::RigidBodyState.new
                        rbs.zero!
                        rbs.time = Time.now
                        rbs.sourceFrame = trsf.from
                        rbs.targetFrame = trsf.to
                        rbs.position = trsf.translation
                        rbs.orientation = trsf.rotation
                        rbs
                    end
                end
            end
        end

        module ClassExtension
            # Allows access to the transformer declaration from the Roby task model
            #
            # It can also be used to define transformer specifications on tasks
            # that don't have one (for instance to tie ports to frames)
            def transformer(*args, &block); orogen_spec.transformer(*args, &block) end
        end
    end

    # Module used to add the 'transforms' annotations to the graph output
    module GraphvizExtension
        def frame_transform_id(task, from, to, prefix= "")
            "frames_#{prefix}#{from}_#{to}_producer"
        end

        def add_frame_transform(task, from, to, prefix = "")
            producer = frame_transform_id(task, from, to, prefix)
            add_vertex(task, producer, "label=\"\",shape=circle")
            add_edge(["frames_#{prefix}#{from}", task], [producer, task], "dir=none")
            add_edge([producer, task], ["frames_#{prefix}#{to}", task], "")
            producer
        end

        def add_transforms_annotations
            plan.find_local_tasks(Orocos::RobyPlugin::Device).each do |device_task|
                tr = device_task.model.transformer
                # Add frame information stored in device definitions
                device_task.each_device do |srv, dev|
                    selected_frame = dev.frame
                    selected_transform = dev.frame_transform
                    next if !selected_frame && !selected_transform

                    if selected_frame
                        frame_id = "frames_#{dev.name}"
                        add_vertex(device_task, frame_id, "label=\"dev(#{dev.name})=#{selected_frame}\",shape=ellipse")
                    end
                    if selected_transform
                        from, to = selected_transform.from, selected_transform.to
                        add_vertex(device_task, "frames_dev_#{dev.name}#{from}", "label=\"dev(#{dev.name}).from=#{from}\",shape=ellipse#{",color=red" if !from}")
                        add_vertex(device_task, "frames_dev_#{dev.name}#{to}", "label=\"dev(#{dev.name}).to=#{to}\",shape=ellipse#{",color=red" if !from}")
                        transform_id = add_frame_transform(device_task, from, to, "dev_#{dev.name}")
                    end

                    # Two cases:
                    #  - the device is using the transformer (has frame
                    #    definitions) and declared a link between the frame
                    #    and the output port. This is handled later.
                    #  - the device is NOT using the transformer. Add the
                    #    vertex and edge now
                    srv.each_output_port(true) do |out_port|
                        next if tr && tr.find_frame_of_port(out_port)

                        if transform_id && Transformer.transform_port?(out_port)
                            add_edge([transform_id, device_task], [out_port, device_task], "dir=none")
                        elsif frame_id
                            add_edge([frame_id, device_task], [out_port, device_task], "dir=none")
                        end
                    end
                end
            end

            # Add frame information stored in tasks (i.e. assigned frames)
            plan.find_local_tasks(Orocos::RobyPlugin::TaskContext).each do |task|
                tr = task.model.transformer
                next if !tr

                edges = Set.new
                tr.each_frame do |frame|
                    color = if !task.selected_frames[frame]
                                ",color=red"
                            end
                    add_vertex(task, "frames_#{frame}", "label=\"#{frame}=#{task.selected_frames[frame]}\",shape=ellipse#{color}")
                    add_edge(["inputs", task], ["frames_#{frame}", task], "style=invis")
                    add_edge(["frames_#{frame}", task], ["outputs", task], "style=invis")
                end
                tr.each_transformation do |trsf|
                    add_vertex(task, "frames_#{trsf.from}_#{trsf.to}_producer", "label=\"\",shape=circle")
                    add_edge(["frames_#{trsf.from}", task], ["frames_#{trsf.from}_#{trsf.to}_producer", task], "dir=none")
                    add_edge(["frames_#{trsf.from}_#{trsf.to}_producer", task], ["frames_#{trsf.to}", task], "")
                end
                tr.each_transform_port do |port, trsf|
                    add_edge([port, task], ["frames_#{trsf.from}_#{trsf.to}_producer", task], "dir=none,constraint=false")
                end
                tr.each_annotated_port do |port, annotated_frame_name|
                    add_edge([port, task], ["frames_#{annotated_frame_name}", task], "dir=none,constraint=false")
                end
            end
        end
    end

    # Implementation of an algorithm that propagates the frame information along
    # the dataflow network, and makes sure that frame selections are consistent.
    class FramePropagation < Orocos::RobyPlugin::DataFlowComputation
        class FrameAnnotation
            attr_reader :task
            attr_reader :frame_name
            attr_reader :selected_frame

            def initialize(task, frame_name, selected_frame)
                @task, @frame_name, @selected_frame = task, frame_name, selected_frame
            end

            def empty?; !@selected_frame end
            def merge(ann)
                if !ann.kind_of?(FrameAnnotation)
                    raise ArgumentError, "cannot merge a frame annotation with a transform annotation. You are probably connecting two ports, one declared as a transform input or output and one only associated with a frame"
                end

                if ann.name != name
                    raise FrameSelectionConflict.new(task, frame_name, selected_frame, ann.name),
                        "invalid network: frame #{frame_name} in #{task} would need to select both #{ann.selected_frame} and #{selected_frame}"
                end
                false
            end

            def to_s
                "#<FrameAnnotation: #{task} #{frame_name}=#{selected_frame}>"
            end
        end

        # Assignment of a transformation during frame propagation
        class TransformAnnotation
            # The task on which we act
            attr_reader :task
            # The task's frame name for the source of the transformation
            attr_reader :from_frame
            # The selected source frame
            attr_reader :from
            # The task's frame name for the target of the transformation
            attr_reader :to_frame
            # The selected target frame
            attr_reader :to

            def initialize(task, from_frame, from, to_frame, to)
                @task = task
                @from_frame = from_frame
                @from = from
                @to_frame = to_frame
                @to   = to
            end

            # Needed by DataFlowComputation
            #
            # Returns true if neither +from+ nor +to+ are set
            def empty?; !@from && !@to end
            # Merge the information of two TransformAnnotation objects.
            #
            # This succeeds only if the two annotations point to the same
            # frames, or if one has nil and the other does not
            def merge(ann)
                if !ann.kind_of?(TransformAnnotation)
                    raise ArgumentError, "cannot merge a frame annotation with a transform annotation. You are probably connecting two ports, one declared as a transform input or output and one only associated with a frame"
                end

                changed = (@from != ann.from) || (@to != ann.to)
                @from ||= ann.from
                @to   ||= ann.to
                if ann.from && ann.from != from
                    raise FrameSelectionConflict.new(task, from_frame, from, ann.from), "incompatible selection: #{ann.from} != #{@from}"
                end
                if ann.to && ann.to != to
                    raise FrameSelectionConflict.new(task, to_frame, to, ann.to), "incompatible selection: #{ann.to} != #{@to}"
                end
                changed
            end

            def pretty_print(pp)
                pp.text "#{from} => #{to}"
            end

            def to_s # :nodoc:
                "#<TransformAnnotation: #{task} #{from_frame}=#{from} => #{to_frame}=#{to}>"
            end
        end

        def self.compute_frames(plan)
            algorithm = FramePropagation.new
            tasks = plan.find_tasks(Orocos::RobyPlugin::TaskContext).to_value_set
            algorithm.propagate(tasks)
        end

        def required_information(tasks)
            result = Hash.new
            tasks.each do |t|
                next if !(tr = t.model.transformer)

                task_info = [nil]
                tr.each_annotated_port do |port, frame|
                    task_info << port
                end
                result[t] = task_info
            end
            result
        end

        Trigger = Orocos::RobyPlugin::DataFlowComputation::Trigger

        def triggering_port_connections(task)
            return if !(tr = task.model.transformer)

            interesting_ports = Set.new

            result = Hash.new
            connections = Set.new

            tr.each_annotated_port do |port, frame|
                interesting_ports << port.name
            end
            tr.each_transform_port do |port, transform|
                interesting_ports << port.name
            end

            interesting_ports.each do |port_name|
                task.each_concrete_input_connection(port_name) do |source_task, source_port, _|
                    connections << [source_task, source_port]
                end
                task.each_concrete_output_connection(port_name) do |_, sink_port, sink_task, _|
                    connections << [sink_task, sink_port]
                end

                if !connections.empty?
                    result[port_name] = Trigger.new(connections, Trigger::USE_PARTIAL)
                    connections = Set.new
                end
            end
            result
        end

        def initial_information(task)
            tr = task.model.transformer

            # Add frame information from the devices if there is some
            # This does not require the presence of a transformer spec
            if task.kind_of?(Orocos::RobyPlugin::Device)
                task.each_device do |srv, dev|
                    selected_frame = dev.frame
                    selected_transform = dev.frame_transform

                    # Two cases:
                    #  - the device is using the transformer (has frame
                    #    definitions). Assign the selected frame
                    #  - the device is NOT using the transformer. Therefore,
                    #    we must only add the relevant port info
                    srv.each_output_port(true) do |out_port|
                        # Do not associate the ports that output transformations
                        if selected_transform && Transformer.transform_port?(out_port)
                            from, to = selected_transform.from, selected_transform.to
                            if tr && (transform = tr.find_transform_of_port(out_port))
                                if from
                                    task.select_frame(transform.from, from)
                                end
                                if to
                                    task.select_frame(transform.to, to)
                                end
                            else
                                add_port_info(task, out_port.name,
                                    TransformAnnotation.new(task, nil, from, nil, to))
                                done_port_info(task, out_port.name)
                            end
                        elsif selected_frame
                            if tr && (frame_name = tr.find_frame_of_port(out_port))
                                task.select_frame(frame_name, selected_frame)
                            else
                                add_port_info(task, out_port.name,
                                    FrameAnnotation.new(task, frame_name, selected_frame))
                                done_port_info(task, out_port.name)
                            end
                        end
                    end
                end
            end

            # Now look for transformer-specific information
            return if !tr

            # Now add information for all ports for which we know the frame
            # already
            tr.each_annotated_port do |port, frame_name|
                if selected_frame = task.selected_frames[frame_name]
                    add_port_info(task, port.name, FrameAnnotation.new(task, frame_name, selected_frame))
                    done_port_info(task, port.name)
                end
            end
            tr.each_transform_output do |port, transform|
                from = task.selected_frames[transform.from]
                to   = task.selected_frames[transform.to]
                add_port_info(task, port.name, TransformAnnotation.new(task, transform.from, from, transform.to, to))
                if from && to
                    done_port_info(task, port.name)
                end
            end
            tr.each_transform_input do |port, transform|
                from = task.selected_frames[transform.from]
                to   = task.selected_frames[transform.to]
                add_port_info(task, port.name, TransformAnnotation.new(task, transform.from, from, transform.to, to))
                if from && to
                    done_port_info(task, port.name)
                end
            end

            Transformer.debug do
                Transformer.debug "initially selected frames for #{task}"
                available_frames = task.model.transformer.available_frames.dup
                task.selected_frames.each do |frame_name, selected_frame|
                    Transformer.debug "  selected #{frame_name} for #{selected_frame}"
                    available_frames.delete(frame_name)
                end
                Transformer.debug "  #{available_frames.size} frames left to pick: #{available_frames.to_a.sort.join(", ")}"
                break
            end
        end

        class PortAssociationMismatch < RuntimeError
            # The problematic endpoint, as a [task, port_name] pair
            attr_reader :endpoint
            # The other side of the problematic connection(s) 
            attr_reader :connections
            # The association type expected by +endpoint+. Can either be 'frame'
            # for an association between a port and a frame, and 'transform' for
            # an association between a port and a transformation.
            attr_reader :association_type

            def initialize(task, port_name, type)
                @endpoint = [task, port_name]
                @association_type = type

                @connections = []
                task.each_concrete_input_connection(port_name) do |source_task, source_port_name, _|
                    @connections << [source_task, source_port_name]
                end
                task.each_concrete_output_connection(port_name) do |_, sink_port_name, sink_task, _|
                    @connections << [sink_task, sink_port_name]
                end
            end

            def pretty_print(pp)
                pp.text "#{endpoint[0]}.#{endpoint[1]} was expecting an association with a #{association_type}, but one or more connections mismatch"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(connections) do |conn|
                        pp.text "#{conn[0]}.#{conn[1]}"
                    end
                end
            end
        end

        # Computes the set of ports and selected frames that can give an insight
        # as to the error represented by +e+
        def refine_invalid_frame_selection(e)
            related_ports = []
            tr = e.task.model.transformer
            tr.each_annotated_port do |port, frame_name|
                next if !has_information_for_port?(e.task, port.name)
                if frame_name == e.frame
                    related_ports << [port.name, :selected_frame]
                end
            end
            tr.each_transform_port do |port, transform|
                next if !has_information_for_port?(e.task, port.name)
                if transform.from == e.frame
                    related_ports << [port.name, :from]
                end
                if transform.to == e.frame
                    related_ports << [port.name, :to]
                end
            end

            related_ports.each do |port_name, accessor|
                info = port_info(e.task, port_name)
                selected_frame = info.send(accessor)

                e.task.each_concrete_input_connection(port_name) do |source_task, source_port, _|
                    e.related_ports << [source_task, source_port, selected_frame]
                end
                e.task.each_concrete_output_connection(port_name) do |source_port, sink_port, sink_task, _|
                    e.related_ports << [sink_task, sink_port, selected_frame]
                end
            end
        end

        def propagate_task(task)
            return if !(tr = task.model.transformer)

            # First, save the port annotations into the select_frames hash on
            # the task.
            tr.each_annotated_port do |port, frame|
                if has_information_for_port?(task, port.name)
                    info = port_info(task, port.name)
                    if !info.respond_to?(:selected_frame)
                        raise PortAssociationMismatch.new(task, port.name, 'frame')
                    end

                    begin
                        task.select_frame(frame, info.selected_frame)
                    rescue InvalidFrameSelection => e
                        refine_invalid_frame_selection(e)
                        raise e, e.message, e.backtrace
                    end
                end
            end
            tr.each_transform_port do |port, transform|
                next if !has_information_for_port?(task, port.name)
                info = port_info(task, port.name)

                begin
                    if info.from
                        task.select_frame(transform.from, info.from)
                    end
                    if info.to
                        task.select_frame(transform.to, info.to)
                    end
                rescue InvalidFrameSelection => e
                    refine_invalid_frame_selection(e)
                    raise e, e.message, e.backtrace
                end
            end

            # Then propagate newly found information to ports that are
            # associated with the frames
            has_all = true
            tr.each_annotated_port do |port, frame_name|
                next if has_final_information_for_port?(task, port.name)

                if selected_frame = task.selected_frames[frame_name]
                    if !has_information_for_port?(task, port.name)
                        add_port_info(task, port.name, FrameAnnotation.new(task, frame_name, selected_frame))
                        done_port_info(task, port.name)
                    end
                else
                    has_all = false
                end
            end
            tr.each_transform_port do |port, transform|
                next if has_final_information_for_port?(task, port.name)
                from = task.selected_frames[transform.from]
                to   = task.selected_frames[transform.to]
                add_port_info(task, port.name, TransformAnnotation.new(task, transform.from, from, transform.to, to))
                if from && to
                    done_port_info(task, port.name)
                else
                    has_all = false
                end
            end
            return has_all
        end

        def self.initialize_selected_frames(task, current_selection)
            # Do selection for the frames that can't be configured anyways
            if task.model.respond_to?(:transformer) && (tr = task.model.transformer)
                tr.each_statically_mapped_frame do |frame_name|
                    task.select_frames(frame_name => frame_name)
                end
            end

            if task.requirements
                new_selection = task.requirements.frame_mappings
            else
                new_selection = Hash.new
            end

            # If the task is associated to a device, check the frame
            # declarations on the device declaration, and assign them. The
            # assignation is done through the port (i.e. device->port and
            # port->frame), so it requires frame-to-port or transform-to-port
            # associations
            if task.respond_to?(:each_device) && (tr = task.model.transformer)
                task.each_device do |srv, dev|
                    selected_frame = dev.frame
                    selected_transform = dev.frame_transform

                    # Two cases:
                    #  - the device is using the transformer (has frame
                    #    definitions). Assign the selected frame
                    #  - the device is NOT using the transformer. Therefore,
                    #    we must only add the relevant port info
                    #
                    # This part covers the part where we have to store the frame
                    # selection (first part). The second part is covered in
                    # #initial_information
                    srv.each_output_port(true) do |out_port|
                        # Do not associate the ports that output transformations
                        if selected_transform && Transformer.transform_port?(out_port)
                            from, to = selected_transform.from, selected_transform.to
                            if transform = tr.find_transform_of_port(out_port)
                                if from
                                    new_selection[transform.from] = from
                                end
                                if to
                                    new_selection[transform.to] = to
                                end
                            end
                        elsif selected_frame
                            if frame_name = tr.find_frame_of_port(out_port)
                                new_selection[frame_name] = selected_frame
                            end
                        end
                    end
                end
            end

            if new_selection.empty?
                task.select_frames(current_selection)
            else
                debug { "adding frame selection from #{task}: #{new_selection}" }
                task.select_frames(new_selection)
            end
        end

        def self.initialize_transform_producers(task, current_selection)
            if task.requirements
                new_selection = task.requirements.transform_producers
            else
                new_selection = Hash.new
            end

            task.transform_producers =
                if new_selection.empty?
                    current_selection.dup
                else
                    new_selection.dup
                end
        end
    end

    # Adds the transformation producers needed to properly setup the system.
    #
    # +engine.transformer_config+ must contain the transformation configuration
    # object.
    def self.add_needed_producers(engine, plan)
        config = engine.transformer_config

        plan.find_local_tasks(Orocos::RobyPlugin::TaskContext).each do |task|
            next if !(tr = task.model.transformer)
            Transformer.debug { "computing needed static and dynamic transformations for #{task}" }

            static_transforms  = Hash.new
            dynamic_transforms = Hash.new { |h, k| h[k] = Array.new }
            tr.each_needed_transformation do |trsf|
                from = task.selected_frames[trsf.from]
                to   = task.selected_frames[trsf.to]
                if !from || !to
                    # This is validated in #validate_generated_network. Just
                    # ignore here.
                    #
                    # We do that so that the :validate_network option to
                    # Engine#instanciate applies
                    next
                end

                self_producers = task.transform_producers.dup
                tr.each_transform_port do |port, transform|
                    if port.kind_of?(Orocos::Spec::InputPort) && task.connected?(port.name)
                        port_from = task.selected_frames[transform.from]
                        port_to   = task.selected_frames[transform.to]
                        self_producers[[port_from, port_to]] = port
                    end
                end

                Transformer.debug do
                    Transformer.debug "looking for chain for #{from} => #{to} in #{task}"
                    Transformer.debug "  with local producers: #{self_producers}"
                end
                chain =
                    begin
                        config.transformation_chain(from, to, self_producers)
                    rescue Exception => e
                        if engine.options[:validate_network]
                            raise InvalidChain.new(task, trsf.from, from, trsf.to, to, e),
                                "cannot find a transformation chain to produce #{from} => #{to} for #{task} (task-local frames: #{trsf.from} => #{trsf.to}): #{e.message}", e.backtrace
                        else
                            next
                        end
                    end
                Transformer.log_pp(:debug, chain)

                static, dynamic = chain.partition
                Transformer.debug do
                    Transformer.debug "#{static.size} static transformations"
                    Transformer.debug "#{dynamic.size} dynamic transformations"
                    break
                end

                static.each do |trsf|
                    static_transforms[[trsf.from, trsf.to]] = trsf
                end
                dynamic.each do |dyn|
                    if dyn.producer.kind_of?(Orocos::Spec::InputPort)
                        next
                    end
                    dynamic_transforms[dyn.producer] << dyn
                end
            end

            task.static_transforms = static_transforms.values
            dynamic_transforms.each do |producer, transformations|
                producer_task = engine.add_instance(producer)
                task.should_start_after producer_task.start_event
                transformations.each do |dyn|
                    task.depends_on(producer_task, :role => "transformer_#{dyn.from}2#{dyn.to}")

                    out_port = producer_task.find_port_for_transform(dyn.from, dyn.to)
                    if !out_port
                        raise TransformationPortNotFound.new(producer_task, dyn.from, dyn.to)
                    end
                    producer_task.select_port_for_transform(out_port, dyn.from, dyn.to)
                    producer_task.connect_ports(task, [out_port.name, "dynamic_transformations"] => Hash.new)
                end
            end
        end
    end

    # Exception raised when a needed frame is not assigned
    class MissingFrame < RuntimeError; end

    # Module used to add some functionality to Orocos::RobyPlugin::Engine
    module EngineExtension
        attr_predicate :transformer_enabled?, true

        # Holds the Transformer::TransformationManager object that stores the
        # current global transformer configuration (static/dynamic
        # transformation configuration)
        attribute(:transformer_config) do
            Transformer::TransformationManager.new do |producer|
                if !self.valid_definition?(producer)
                    raise ArgumentError, "#{producer} is not a known device, definition or instance requirements object"
                end
            end
        end

        attribute(:selected_frames) { Hash.new }

        # Declare a global selection for a frame. 
        def use_frames(spec)
            selected_frames.merge!(spec)
            self
        end

        attribute(:transform_producers) { Hash.new }

        # Declare a global selection for dynamic frame production. This can be
        # used to override settings in the transformer configuration file, and
        # in order to be consistent with the #use_transform_producer statement
        # on instance requirements
        def use_transform_producer(from, to, spec)
            transform_producers[[from, to]] = spec
            self
        end

        # During network validation, checks that all required frames have been
        # configured
        def validate_generated_network(plan, options)
            super if defined? super

            if transformer_enabled?
                plan.find_local_tasks(Orocos::RobyPlugin::TaskContext).each do |task|
                    next if !(tr = task.model.transformer)

                    tr.each_needed_transformation do |transform|
                        if !task.selected_frames[transform.from]
                            raise MissingFrame, "could not find a frame assignment for #{transform.from} in #{task}"
                        end
                        if !task.selected_frames[transform.to]
                            raise MissingFrame, "could not find a frame assignment for #{transform.to} in #{task}"
                        end
                    end
                end
            end
        end

        # Loads the transformer configuration file from +path+ into the engine's
        # configuration.
        #
        # The configuration is overlaid over the current configuration. Use
        # #clean_transformer_conf to start it from scratch
        def load_transformer_conf(*path)
            args = path + [:order => :specific_first]
            file = Roby.app.find_file(*args)
            transformer_config.load_configuration(file)
        end

        # Passes calls to the transformer config
        def method_missing(m, *args, &block)
            if m == :static_transform || m == :dynamic_transform || m == :frames
                return transformer_config.conf.send(m, *args, &block)
            end
            super
        end
    end

    Orocos::RobyPlugin::Engine.register_model_postprocessing do |system_model|
        # For every composition, ignore all dynamic_transformations ports
        system_model.ignore_port_for_autoconnection Orocos::Spec::InputPort, 'dynamic_transformations', '/base/samples/RigidBodyState'
    end

    Orocos::RobyPlugin::Engine.register_instanciation_postprocessing do |engine, plan|
        if engine.transformer_enabled?
            # Transfer the frame mapping information from the instance specification
            # objects to the selected_frames hashes on the tasks
            tasks = plan.find_local_tasks(Orocos::RobyPlugin::Component).roots(Roby::TaskStructure::Hierarchy)
            tasks.each do |root_task|
                FramePropagation.initialize_selected_frames(root_task, engine.selected_frames.dup)
                FramePropagation.initialize_transform_producers(root_task, engine.transform_producers.dup)
                Roby::TaskStructure::Hierarchy.each_bfs(root_task, BGL::Graph::ALL) do |from, to, info|
                    FramePropagation.initialize_selected_frames(to, from.selected_frames)
                    FramePropagation.initialize_transform_producers(to, from.transform_producers)
                end

            end
        end
    end

    Orocos::RobyPlugin::Engine.register_instanciated_network_postprocessing do |engine, plan, validate|
        if engine.transformer_enabled?
            FramePropagation.compute_frames(plan)

            # Now find out the frame producers that each task needs, and add them to
            # the graph
            add_needed_producers(engine, plan)
        end
    end
end

Orocos::RobyPlugin::Component.include Transformer::ComponentExtension
Orocos::RobyPlugin::Component.extend Transformer::ComponentModelExtension
Orocos::RobyPlugin::TaskContext.include Transformer::TaskContextExtension
Orocos::RobyPlugin::Composition.include Transformer::CompositionExtension

Orocos::RobyPlugin::DeviceInstance.include Transformer::DeviceExtension
Orocos::RobyPlugin::Graphviz.include Transformer::GraphvizExtension
Orocos::RobyPlugin::InstanceRequirements.include Transformer::InstanceRequirementsExtension
Orocos::RobyPlugin::Engine.include Transformer::EngineExtension
Roby.app.filter_out_patterns.push(/^#{Regexp.quote(__FILE__)}/)
