# frozen_string_literal: true

module NittyMail
  module Utils
    module_function

    # Create a standardized progress bar
    def progress_bar(title:, total:)
      require "ruby-progressbar"
      ProgressBar.create(
        title: title,
        total: total,
        format: "%t: |%B| %p%% (%c/%C) [%e]"
      )
    end
  end
end
