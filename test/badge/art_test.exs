defmodule Badge.ArtTest do
  use ExUnit.Case, async: true

  alias Badge.Art

  describe "share_size/0" do
    test "is the stored share art's dimensions" do
      assert Art.share_size() == {144, 64}
    end
  end

  describe "tint/2" do
    test "turns each alpha byte into an rgba8888 pixel in the given colour" do
      assert Art.tint(<<0, 128, 255>>, 0x102030) ==
               <<0x10, 0x20, 0x30, 0, 0x10, 0x20, 0x30, 128, 0x10, 0x20, 0x30, 255>>
    end

    test "keeps every pixel in order across rows" do
      {width, _height} = Art.share_size()
      mask = :erlang.list_to_binary(for i <- 1..(width * 2 + 5), do: rem(i, 256))
      expected = for <<alpha <- mask>>, into: <<>>, do: <<0x10, 0x20, 0x30, alpha>>

      assert Art.tint(mask, 0x102030) == expected
    end
  end

  describe "share/1" do
    test "reads the real mask in the simulator, tinted, at the compiled size" do
      assert {:rgba8888, 144, 64, bytes} = Art.share(0x102030)
      assert byte_size(bytes) == 144 * 64 * 4
    end
  end

  describe "share/2" do
    test "a partition without the art answers undefined, which is no image rather than a crash" do
      assert Art.share(:undefined, 0xFFFFFF) == nil
    end

    test "anything that is not the bytes is no image either" do
      assert Art.share(:some_other_atom, 0xFFFFFF) == nil
    end
  end
end
