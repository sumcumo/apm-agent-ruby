# frozen_string_literal: true

require 'elastic_apm'
require 'opentracing'

module ElasticAPM
  module OpenTracing
    # @api private
    class Span
      def initialize(elastic_span, span_context)
        @elastic_span = elastic_span
        @span_context = span_context
      end

      attr_reader :elastic_span

      def operation_name=(name)
        elastic_span.name = name
      end

      def context
        @span_context
      end

      def set_label(key, val)
        set_tag(key, val)
        val
      end

      def set_tag(key, val)
        val = sanitize_tag_value(val)
        if elastic_span.is_a?(Transaction)
          case key.to_s
          when 'type'
            elastic_span.type = val
          when 'result'
            elastic_span.result = val
          when /user\.(\w+)/
            set_user_value($1, val)
          else
            elastic_span.context.labels[key] = val
          end
        else
          elastic_span.context.labels[key] = val
        end
        self
      end

      def sanitize_tag_value(value)
        case value
        when String, Numeric, TrueClass, FalseClass, NilClass
          return value
        else
          return value.inspect
        end
      end

      def set_baggage_item(_key, _value)
        ElasticAPM.agent.config.logger.warn(
          'Baggage is not supported by ElasticAPM'
        )
      end

      def get_baggage_item(_key)
        ElasticAPM.agent.config.logger.warn(
          'Baggage is not supported by ElasticAPM'
        )

        nil
      end

      # rubocop:disable Lint/UnusedMethodArgument
      def log_kv(timestamp: nil, **fields)
        if (exception = fields[:'error.object'])
          ElasticAPM.report exception
        elsif (message = fields[:message])
          ElasticAPM.report_message message
        end
      end
      # rubocop:enable Lint/UnusedMethodArgument

      def finish(_clock_end: nil, end_time: Time.now)
        return unless (agent = ElasticAPM.agent)

        elastic_span.done clock_end: Util.micros(end_time)

        case elastic_span
        when ElasticAPM::Transaction
          agent.instrumenter.current_transaction = nil
        when ElasticAPM::Span
          agent.instrumenter.current_spans.delete(elastic_span)
        end

        agent.enqueue elastic_span
      end

      private

      def set_user_value(key, value)
        return unless elastic_span.is_a?(Transaction)

        setter = :"#{key}="
        return unless elastic_span.context.user.respond_to?(setter)
        elastic_span.context.user.send(setter, value)
      end
    end

    # @api private
    class SpanContext
      extend Forwardable

      def initialize(trace_context:, baggage: nil)
        if baggage
          ElasticAPM.agent.config.logger.warn(
            'Baggage is not supported by ElasticAPM'
          )
        end

        @trace_context = trace_context
      end

      attr_accessor :trace_context
      attr_reader :baggage

      def_delegators :trace_context, :trace_id, :id, :parent_id

      def to_header
        trace_context.traceparent.to_header
      end

      def self.parse(header)
        return unless header

        trace_context = ElasticAPM::TraceContext.parse(header)
        return unless trace_context

        trace_context.traceparent.id = trace_context.traceparent.parent_id
        trace_context.traceparent.parent_id = nil

        from_trace_context(trace_context)
      end

      def self.from_trace_context(trace_context)
        new(trace_context: trace_context)
      end

      def child
        self.class.from_trace_context(trace_context.child)
      end
    end

    # @api private
    class Scope
      def initialize(span, scope_stack, finish_on_close:)
        @span = span
        @scope_stack = scope_stack
        @finish_on_close = finish_on_close
      end

      attr_reader :span

      def elastic_span
        span.elastic_span
      end

      def close
        @span.finish if @finish_on_close
        @scope_stack.pop
      end
    end

    # @api private
    class ScopeStack
      KEY = :__elastic_apm_ot_scope_stack

      def push(scope)
        scopes << scope
      end

      def pop
        scopes.pop
      end

      def last
        scopes.last
      end

      private

      def scopes
        Thread.current[KEY] ||= []
      end
    end

    # @api private
    class ScopeManager
      def initialize
        @scope_stack = ScopeStack.new
      end

      def activate(span, finish_on_close: true)
        return active if active && active.span == span

        scope = Scope.new(span, @scope_stack, finish_on_close: finish_on_close)
        @scope_stack.push scope
        scope
      end

      def active
        @scope_stack.last
      end
    end
    # A custom tracer to use the OpenTracing API with ElasticAPM
    class Tracer
      def initialize
        @scope_manager = ScopeManager.new
      end

      attr_reader :scope_manager

      def active_span
        scope_manager.active&.span
      end

      # rubocop:disable Metrics/ParameterLists
      def start_active_span(
        operation_name,
        child_of: nil,
        references: nil,
        start_time: Time.now,
        labels: nil,
        tags: {},
        ignore_active_scope: false,
        finish_on_close: true,
        **
      )
        labels ||= tags
        span = start_span(
          operation_name,
          child_of: child_of,
          references: references,
          start_time: start_time,
          labels: labels,
          ignore_active_scope: ignore_active_scope
        )
        scope = scope_manager.activate(span, finish_on_close: finish_on_close)

        if block_given?
          begin
            return yield scope
          ensure
            scope.close
          end
        end

        scope
      end
      # rubocop:enable Metrics/ParameterLists

      # rubocop:disable Metrics/ParameterLists
      def start_span(
        operation_name,
        child_of: nil,
        references: nil,
        start_time: Time.now,
        labels: nil,
        tags: {},
        ignore_active_scope: false,
        **
      )
        labels ||= tags
        span_context = prepare_span_context(
          child_of: child_of,
          references: references,
          ignore_active_scope: ignore_active_scope
        )

        if span_context
          trace_context =
            span_context.respond_to?(:trace_context) &&
            span_context.trace_context
        end

        elastic_span =
          if ElasticAPM.current_transaction
            ElasticAPM.start_span(
              operation_name,
              trace_context: trace_context
            )
          else
            ElasticAPM.start_transaction(
              operation_name,
              trace_context: trace_context
            )
          end

        # if no Elastic APM agent is running or transaction not sampled
        unless elastic_span
          return ::OpenTracing::Span::NOOP_INSTANCE
        end

        span_context ||=
          SpanContext.from_trace_context(elastic_span.trace_context)

        elastic_span.start Util.micros(start_time)

        Span.new(elastic_span, span_context).tap do |span|
          labels.each { |key, value| span.set_tag(key, value) }
        end
      end
      # rubocop:enable Metrics/ParameterLists

      def inject(span_context, format, carrier)
        case format
        when ::OpenTracing::FORMAT_RACK, ::OpenTracing::FORMAT_TEXT_MAP
          carrier['elastic-apm-traceparent'] =
            span_context.to_header
        else
          warn 'Only injection via FORMAT_TEXT_MAP or via HTTP headers and ' \
            'FORMAT_RACK is available'
        end
      end

      def extract(format, carrier)
        case format
        when ::OpenTracing::FORMAT_RACK, ::OpenTracing::FORMAT_TEXT_MAP
          SpanContext.parse(carrier['HTTP_ELASTIC_APM_TRACEPARENT'] ||
            carrier['elastic-apm-traceparent'])

        else
          warn 'Only extraction via FORMAT_TEXT_MAP or via HTTP headers and ' \
            'FORMAT_RACK is available'
          nil
        end
      rescue ElasticAPM::TraceContext::InvalidTraceparentHeader
        nil
      end

      private

      def prepare_span_context(
        child_of:,
        references:,
        ignore_active_scope:
      )
        context = context_from_child_of(child_of) ||
                  context_from_references(references) ||
                  context_from_active_scope(ignore_active_scope)
        return context.child if context&.respond_to?(:child)

        context
      end

      def context_from_child_of(child_of)
        return unless child_of
        child_of.respond_to?(:context) ? child_of.context : child_of
      end

      def context_from_references(references)
        return if !references || references.none?

        child_of = references.find do |reference|
          reference.type == ::OpenTracing::Reference::CHILD_OF
        end

        (child_of || references.first).context
      end

      def context_from_active_scope(ignore_active_scope)
        if ignore_active_scope
          ElasticAPM.agent&.config&.logger&.warn(
            'ignore_active_scope might lead to unexpected results'
          )
          return
        end
        @scope_manager.active&.span&.context
      end
    end
  end
end
