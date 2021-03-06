import ../db/[db_chain, state_db], eth_common, chronicles, ../vm_state, ../vm_types, ../transaction, ranges,
  ../vm/[computation, interpreter_dispatch, message, interpreter/vm_forks], ../constants, stint, nimcrypto,
  ../vm_state_transactions, sugar, ../utils, eth_trie/db, ../tracer, ./executor, json,
  eth_bloom, strutils

type
  # TODO: these types need to be removed
  # once eth_bloom and eth_common sync'ed
  Bloom = eth_common.BloomFilter
  LogsBloom = eth_bloom.BloomFilter

# TODO: move these three receipt procs below somewhere else more appropriate
func logsBloom(logs: openArray[Log]): LogsBloom =
  for log in logs:
    result.incl log.address
    for topic in log.topics:
      result.incl topic

func createBloom*(receipts: openArray[Receipt]): Bloom =
  var bloom: LogsBloom
  for receipt in receipts:
    bloom.value = bloom.value or logsBloom(receipt.logs).value
  result = bloom.value.toByteArrayBE

proc makeReceipt(vmState: BaseVMState, stateRoot: Hash256, cumulativeGasUsed: GasInt, fork = FkFrontier): Receipt =
  if fork < FkByzantium:
    # TODO: which one: vmState.blockHeader.stateRoot or stateDb.rootHash?
    # currently, vmState.blockHeader.stateRoot vs stateDb.rootHash can be different
    # need to wait #188 solved
    result.stateRootOrStatus = hashOrStatus(stateRoot)
  else:
    # TODO: post byzantium fork use status instead of rootHash
    let vmStatus = true # success or failure
    result.stateRootOrStatus = hashOrStatus(vmStatus)

  result.cumulativeGasUsed = cumulativeGasUsed
  result.logs = vmState.getAndClearLogEntries()
  result.bloom = logsBloom(result.logs).value.toByteArrayBE

type
  Chain* = ref object of AbstractChainDB
    db: BaseChainDB

proc newChain*(db: BaseChainDB): Chain =
  result.new
  result.db = db

method genesisHash*(c: Chain): KeccakHash =
  c.db.getBlockHash(0.toBlockNumber)

method getBlockHeader*(c: Chain, b: HashOrNum, output: var BlockHeader): bool =
  case b.isHash
  of true:
    c.db.getBlockHeader(b.hash, output)
  else:
    c.db.getBlockHeader(b.number, output)

method getBestBlockHeader*(c: Chain): BlockHeader =
  c.db.getCanonicalHead()

method getSuccessorHeader*(c: Chain, h: BlockHeader, output: var BlockHeader): bool =
  let n = h.blockNumber + 1
  c.db.getBlockHeader(n, output)

method getBlockBody*(c: Chain, blockHash: KeccakHash): BlockBodyRef =
  result = nil

method persistBlocks*(c: Chain, headers: openarray[BlockHeader], bodies: openarray[BlockBody]): ValidationResult =
  # Run the VM here
  if headers.len != bodies.len:
    debug "Number of headers not matching number of bodies"
    return ValidationResult.Error

  let blockReward = 5.u256 * pow(10.u256, 18) # 5 ETH

  let transaction = c.db.db.beginTransaction()
  defer: transaction.dispose()

  trace "Persisting blocks", fromBlock = headers[0].blockNumber, toBlock = headers[^1].blockNumber
  for i in 0 ..< headers.len:
    let head = c.db.getCanonicalHead()
    var stateDb = newAccountStateDB(c.db.db, head.stateRoot, c.db.pruneTrie)
    var receipts = newSeq[Receipt](bodies[i].transactions.len)

    if bodies[i].transactions.calcTxRoot != headers[i].txRoot:
      debug "Mismatched txRoot", i
      return ValidationResult.Error

    if headers[i].txRoot != BLANK_ROOT_HASH:
      let vmState = newBaseVMState(head, c.db)
      if bodies[i].transactions.len == 0:
        debug "No transactions in body", i
        return ValidationResult.Error
      else:
        trace "Has transactions", blockNumber = headers[i].blockNumber, blockHash = headers[i].blockHash

        var cumulativeGasUsed = GasInt(0)
        for txIndex, tx in bodies[i].transactions:
          var sender: EthAddress
          if tx.getSender(sender):
            let txFee = processTransaction(stateDb, tx, sender, vmState)

            # perhaps this can be altered somehow
            # or processTransaction return only gasUsed
            # a `div` here is ugly and possibly div by zero
            let gasUsed = (txFee div tx.gasPrice.u256).truncate(GasInt)
            cumulativeGasUsed += gasUsed

            # miner fee
            stateDb.addBalance(headers[i].coinbase, txFee)
          else:
            debug "Could not get sender", i, tx
            return ValidationResult.Error
          receipts[txIndex] = makeReceipt(vmState, stateDb.rootHash, cumulativeGasUsed)

    var mainReward = blockReward
    if headers[i].ommersHash != EMPTY_UNCLE_HASH:
      let h = c.db.persistUncles(bodies[i].uncles)
      if h != headers[i].ommersHash:
        debug "Uncle hash mismatch"
        return ValidationResult.Error
      for u in 0 ..< bodies[i].uncles.len:
        var uncleReward = bodies[i].uncles[u].blockNumber + 8.u256
        uncleReward -= headers[i].blockNumber
        uncleReward = uncleReward * blockReward
        uncleReward = uncleReward div 8.u256
        stateDb.addBalance(bodies[i].uncles[u].coinbase, uncleReward)
        mainReward += blockReward div 32.u256

    # Reward beneficiary
    stateDb.addBalance(headers[i].coinbase, mainReward)

    if headers[i].stateRoot != stateDb.rootHash:
      error "Wrong state root in block", blockNumber = headers[i].blockNumber, expected = headers[i].stateRoot, actual = stateDb.rootHash, arrivedFrom = c.db.getCanonicalHead().stateRoot
      # this one is a show stopper until we are confident in our VM's
      # compatibility with the main chain
      raise(newException(Exception, "Wrong state root in block"))

    let bloom = createBloom(receipts)
    if headers[i].bloom != bloom:
      debug "wrong bloom in block", blockNumber = headers[i].blockNumber
    assert(headers[i].bloom == bloom)

    let receiptRoot = calcReceiptRoot(receipts)
    if headers[i].receiptRoot != receiptRoot:
      debug "wrong receiptRoot in block", blockNumber = headers[i].blockNumber, actual=receiptRoot, expected=headers[i].receiptRoot
    assert(headers[i].receiptRoot == receiptRoot)

    discard c.db.persistHeaderToDb(headers[i])
    if c.db.getCanonicalHead().blockHash != headers[i].blockHash:
      debug "Stored block header hash doesn't match declared hash"
      return ValidationResult.Error

    c.db.persistTransactions(headers[i].blockNumber, bodies[i].transactions)
    c.db.persistReceipts(receipts)

  transaction.commit()
