import { useTranslation } from "react-i18next";
import ConnectionLoader from "./renderer/components/ConnectionLoader";

const PendingSession = () => {
    const { t } = useTranslation();

    return <ConnectionLoader label={t("common.connectorSetup.connecting")} indeterminate />;
};

export default PendingSession;
