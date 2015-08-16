old_handler = I18n.config.exception_handler

I18n.config.exception_handler = lambda do |exception, locale, key, options|
  Delayed::Job.enqueue(
    I18nJob.new(locale: locale, key: key, options: options)
  )
  old_handler.call(exception, locale, key, options)
end

I18n.config.enforce_available_locales = true
I18n.enforce_available_locales = true
