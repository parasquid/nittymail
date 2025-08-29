# frozen_string_literal: true

module NittyMail
  module Logging
    module_function

    # Format a concise preview of UIDs slated for syncing
    def format_uids_preview(uids)
      return "uids to be synced: []" if uids.nil? || uids.empty?
      preview_count = [uids.size, 5].min
      preview = uids.first(preview_count).join(", ")
      more = uids.size - preview_count
      suffix = (more > 0) ? ", ... (#{more} more uids)" : ""
      "uids to be synced: [#{preview}#{suffix}]"
    end
  end
end
