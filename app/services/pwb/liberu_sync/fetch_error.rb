# frozen_string_literal: true

module Pwb
  module LiberuSync
    # Liberu (API or photo) could not be read. Raised before any write when the
    # listing itself fails, so a failed run never unpublishes anything.
    class FetchError < StandardError; end
  end
end
