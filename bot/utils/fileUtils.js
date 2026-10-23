const fs = require("node:fs");
const path = require("node:path");

const DATA_DIR = path.resolve(__dirname, "../data");
const RECORDS_PATH = path.join(DATA_DIR, "userRecords.json");
const MOYU_PATH = path.join(DATA_DIR, "moYu.json");

function readRecords(filePath) {
    try {
        return JSON.parse(fs.readFileSync(filePath, "utf8"));
    } catch {
        return {};
    }
}

function writeRecords(filePath, records) {
    fs.mkdirSync(DATA_DIR, { recursive: true });
    fs.writeFileSync(filePath, JSON.stringify(records, null, 2));
}

class FileUtils {
    static recordResult(userName, isWin) {
        const userRecords = readRecords(RECORDS_PATH);
        if (!userRecords[userName]) {
            userRecords[userName] = { totalGames: 0, totalWins: 0 };
        }
        userRecords[userName].totalGames++;
        if (isWin) userRecords[userName].totalWins++;
        writeRecords(RECORDS_PATH, userRecords);

        return {
            totalGames: userRecords[userName].totalGames,
            totalWins: userRecords[userName].totalWins,
            winRate: userRecords[userName].totalWins / userRecords[userName].totalGames,
        };
    }

    static getWinRate() {
        const records = Object.entries(readRecords(RECORDS_PATH));
        records.sort((a, b) => b[1].totalWins / b[1].totalGames - a[1].totalWins / a[1].totalGames);
        return records
            .map(([name, record]) => `${name}  总场数：${record.totalGames}  胜率：${(record.totalWins / record.totalGames).toFixed(2)}\n`)
            .join("");
    }

    static recordMoyu(userName, isWin) {
        const records = readRecords(MOYU_PATH);
        if (!records[userName]) records[userName] = { totalGames: 0, totalWins: 0 };
        records[userName].totalGames++;
        if (isWin) records[userName].totalWins++;
        writeRecords(MOYU_PATH, records);

        return {
            totalGames: records[userName].totalGames,
            totalWins: records[userName].totalWins,
            winRate: records[userName].totalWins / records[userName].totalGames,
        };
    }

    static getMoyuRate() {
        const records = Object.entries(readRecords(MOYU_PATH));
        records.sort((a, b) => b[1].totalWins / b[1].totalGames - a[1].totalWins / a[1].totalGames);
        return records.map(([name, record]) => `${name}  总摸鱼量：${record.totalGames}\n`).join("");
    }
}

module.exports = FileUtils;
