{:ok, _} = ExGram.start_link()
{:ok, _} = ExGram.Adapter.Test.start_link()
ExUnit.start()
