"""Rear event protocol: encode/decode, CRC, resync, clip reassembly, drops."""

import random
import unittest

from backend.rear import protocol as p


def ev(**kw):
    d = dict(t_ms=123456, k_peak=22600, k_left=1000, k_center=20600, k_right=1000, region=p.REGION_CENTER,
             width=16, height=12, frame_count=4, trigger_index=3)
    d.update(kw)
    return p.Event(**d)


def frames(n=4, size=16 * 12):
    return [bytes((i * 31 + j) & 0xFF for j in range(size)) for i in range(n)]


class Assembled:
    def __init__(self):
        self.log = []
        self.asm = p.ClipAssembler(lambda e, eid: self.log.append(("event", eid, e)),
                                   lambda c: self.log.append(("clip", c)),
                                   lambda h: self.log.append(("hb", h)))

    def feed_all(self, packets):
        for pk in packets:
            self.asm.feed(p.decode(pk))

    @property
    def clips(self):
        return [x[1] for x in self.log if x[0] == "clip"]


class Packets(unittest.TestCase):
    def test_crc_check_value(self):
        self.assertEqual(p.crc16(b"123456789"), 0x29B1)

    def test_round_trip_every_type(self):
        bodies = [ev(), p.FrameChunk(2, 1, 3, 2500, b"\x01\x02\x03"), p.End(30, 0xBEEF, p.END_TRUNCATED),
                  p.Heartbeat(99999, 3)]
        for body in bodies:
            pkt = p.decode(p.encode(body, event_id=513, seq=42))
            self.assertEqual(pkt.body, body)
            self.assertEqual((pkt.event_id, pkt.seq, pkt.type), (513, 42, p.TYPE_OF[type(body)]))

    def test_documented_example(self):
        # Same bytes as the worked example in docs/rear_event_protocol.md.
        pkt = p.encode(p.Event(t_ms=123456, k_peak=22600, k_left=1000, k_center=20600, k_right=1000,
                               region=p.REGION_CENTER), event_id=7, seq=0)
        self.assertEqual(pkt.hex(" "), "a5 5a 01 01 07 00 00 00 20 00 40 e2 01 00 48 58 00 00 e8 03 00 00 "
                                       "78 50 00 00 e8 03 00 00 a0 00 78 00 1e 00 1d 00 0a 00 02 01 02 33")

    def test_little_endian_header(self):
        pkt = p.encode(p.End(1, 2), event_id=0x0102, seq=0x0304)
        self.assertEqual(pkt[:2], b"\xA5\x5A")
        self.assertEqual(pkt[4:8], b"\x02\x01\x04\x03")
        self.assertEqual(int.from_bytes(pkt[8:10], "little"), p.END_FMT.size)

    def test_any_flipped_bit_fails_crc(self):
        good = p.encode(ev(), 1, 0)
        for i in range(2, len(good)):                    # every byte after SYNC
            bad = bytearray(good)
            bad[i] ^= 0x10
            with self.assertRaises(p.ProtocolError):
                p.decode(bytes(bad))

    def test_rejects_bad_version_type_length(self):
        good = bytearray(p.encode(p.End(1, 2), 1, 0))
        for i, v in ((2, 9), (3, 0x7F)):
            bad = bytearray(good)
            bad[i] = v
            with self.assertRaises(p.ProtocolError):
                p.decode(bytes(bad))
        with self.assertRaises(p.ProtocolError):
            p.decode(bytes(good[:-1]))


class Stream(unittest.TestCase):
    def test_resync_through_garbage_and_split_reads(self):
        pkts = p.encode_event(ev(), frames(), 5)
        stream = b"\x00\xA5\xFFjunk" + b"".join(pkts[:3]) + b"\xA5\x5A\x01" + b"".join(pkts[3:])
        parser, out = p.StreamParser(), []
        rng = random.Random(0)
        i = 0
        while i < len(stream):                           # arbitrary read sizes, like a serial port
            n = rng.randint(1, 37)
            out += parser.feed(stream[i:i + n])
            i += n
        self.assertEqual([x.seq for x in out], list(range(len(pkts))))

    def test_corrupt_packet_dropped_rest_kept(self):
        pkts = p.encode_event(ev(), frames(), 5)
        bad = bytearray(pkts[2])
        bad[-1] ^= 0xFF
        parser = p.StreamParser()
        out = parser.feed(b"".join(pkts[:2]) + bytes(bad) + b"".join(pkts[3:]))
        self.assertEqual(len(out), len(pkts) - 1)
        self.assertNotIn(2, [x.seq for x in out])
        self.assertGreaterEqual(parser.errors, 1)


class Reassembly(unittest.TestCase):
    def test_complete_clip(self):
        a, f = Assembled(), frames()
        a.feed_all(p.encode_event(ev(), f, 9))
        clip = a.clips[0]
        self.assertTrue(clip.complete)
        self.assertEqual(clip.frames, f)
        self.assertTrue(clip.crc_ok)

    def test_event_reported_before_any_frame(self):
        a = Assembled()
        pkts = p.encode_event(ev(), frames(), 9)
        a.asm.feed(p.decode(pkts[0]))
        self.assertEqual([x[0] for x in a.log], ["event"])          # warn now, clip still coming
        a.feed_all(pkts[1:])
        self.assertEqual([x[0] for x in a.log], ["event", "clip"])

    def test_multi_chunk_frames(self):
        f = [bytes([i]) * 2600 for i in range(3)]                    # 3 chunks per frame
        a = Assembled()
        a.feed_all(p.encode_event(ev(width=52, height=50, frame_count=3), f, 1))
        self.assertTrue(a.clips[0].complete)
        self.assertEqual(a.clips[0].frames, f)

    def test_dropped_chunk_leaves_hole(self):
        f = [bytes([i]) * 2600 for i in range(3)]
        pkts = p.encode_event(ev(width=52, height=50, frame_count=3), f, 1)
        a = Assembled()
        a.feed_all(pkts[:4] + pkts[5:])                              # lose one chunk of frame 1
        clip = a.clips[0]
        self.assertIsNone(clip.frames[1])
        self.assertEqual(clip.frames[0], f[0])
        self.assertFalse(clip.complete)
        self.assertFalse(clip.crc_ok)
        self.assertEqual(clip.dropped_packets, 1)

    def test_missing_end_flushes_partial(self):
        pkts = p.encode_event(ev(), frames(), 3)
        a = Assembled()
        a.feed_all(pkts[:-1])
        self.assertEqual(a.clips, [])
        a.asm.flush()
        clip = a.clips[0]
        self.assertIsNone(clip.end)
        self.assertIsNone(clip.crc_ok)
        self.assertEqual(sum(fr is not None for fr in clip.frames), 4)

    def test_new_event_closes_unfinished_clip(self):
        a = Assembled()
        first = p.encode_event(ev(), frames(), 1)
        a.feed_all(first[:3] + p.encode_event(ev(), frames(), 2))
        self.assertEqual([c.event_id for c in a.clips], [1, 2])
        self.assertFalse(a.clips[0].complete)
        self.assertTrue(a.clips[1].complete)

    def test_wrong_clip_crc(self):
        pkts = p.encode_event(ev(), frames(), 4)
        pkts[-1] = p.encode(p.End(4, 0x0000), 4, p.decode(pkts[-1]).seq)
        a = Assembled()
        a.feed_all(pkts)
        self.assertFalse(a.clips[0].crc_ok)
        self.assertFalse(a.clips[0].complete)

    def test_chunks_of_unknown_event_ignored(self):
        pkts = p.encode_event(ev(), frames(), 4)
        a = Assembled()
        a.feed_all(pkts[1:])                                         # EVENT lost
        self.assertEqual(a.log, [])

    def test_heartbeat(self):
        a = Assembled()
        a.feed_all([p.encode(p.Heartbeat(1000, 3), 0, 0)])
        self.assertEqual(a.log[0][0], "hb")


if __name__ == "__main__":
    unittest.main()
