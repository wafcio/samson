# frozen_string_literal: true
# http://stackoverflow.com/questions/5490411/counting-the-number-of-queries-performed/43810063#43810063
class ActiveSupport::TestCase
  def sql_queries(&block)
    queries = []
    counter = ->(*, payload) do
      queries << payload.fetch(:sql) unless ["CACHE", "SCHEMA"].include?(payload.fetch(:name))
    end

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)

    queries
  end

  def assert_sql_queries(expected, &block)
    queries = sql_queries(&block)
    queries.count.must_equal(
      expected,
      "Expected #{expected} queries, but found #{queries.count}:\n#{queries.join("\n")}"
    )
  end
end
