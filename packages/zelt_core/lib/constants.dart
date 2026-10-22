/// Protocol constants. Changing any of these breaks wire compatibility.
library;

/// v2: LIONESS payloads, versioned and signature-authenticated link
/// handshake, rotating onion keys (1-byte key ID in the header). Nodes of different
/// versions refuse each other cleanly (see Link).
const int protocolVersion = 2;

// --- Onion packets (Sphinx-style) ---------------------------------------

/// Every packet on the wire has exactly this size.
const int packetSize = 8192;

const int minHops = 3;
const int maxHops = 7;
const int defaultHops = 4;

/// One routing slot per relay: cmd(1) delay(4) addr(19) nodePk(32)
/// nextEph(32) nextMac(16) extra(16).
const int slotSize = 120;
const int numSlots = maxHops;
const int routingSize = slotSize * numSlots;
/// keyId(1) eph(32) mac(16) routing.
const int headerSize = 1 + 32 + 16 + routingSize;
const int payloadSize = packetSize - headerSize;

/// Size of the encrypted blob a mailbox relay stores.
const int blobSize = 7168;

/// Largest UTF-8 text a single message may carry (UI limit, leaves room).
const int maxTextBytes = 6000;

// --- Relay rules --------------------------------------------------------

const int relayCapBytes = 12 * 1024 * 1024;
const Duration relayTtl = Duration(days: 7);
const int slotQuotaBytes = 512 * 1024;
const int publicSlotQuotaBytes = 128 * 1024;
const int publicTotalQuotaBytes = 2 * 1024 * 1024;
const int handoffQuotaBytes = 4 * 1024 * 1024;

/// Credentials (token batches) are valid for this many token epochs.
const int tokenEpochDays = 7;
const int tokenEpochWindow = 4;
const int tokensPerCredential = 4096;

/// Public slots are handed out to strangers asking over the onion network.
const int firstPublicSlot = 0x8000;

// --- Peers --------------------------------------------------------------

const int targetPeers = 12;
const int maxPeersPerSource = 3;
const int maxPeersPerRange = 3;
const int anchorPeers = 4;
const int maxMailboxRelays = 6;
const int copiesPerMessage = 3;

const int defaultPort = 47017;

// --- Mailboxes ----------------------------------------------------------

/// Mailbox IDs rotate once per epoch.
const Duration mailboxEpoch = Duration(days: 1);

/// Number of past epochs the recipient keeps polling (covers the TTL).
const int mailboxLookback = 7;

int mailboxEpochOf(DateTime t) =>
    t.millisecondsSinceEpoch ~/ mailboxEpoch.inMilliseconds;

int tokenEpochOf(DateTime t) =>
    t.millisecondsSinceEpoch ~/ const Duration(days: tokenEpochDays).inMilliseconds;

// --- DHT ----------------------------------------------------------------

const int dhtK = 8;
const int dhtAlpha = 3;
